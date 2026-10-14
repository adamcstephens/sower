use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{Read, Write};
use std::net::Ipv4Addr;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use super::network_host as host;
use super::network_policy::{Policy, PolicyFile, valid_unit};
use super::peercred::PeerCredentials;
use super::protocol::Request;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Phase {
    Reserved,
    Allocated,
    Active,
    Revoked,
    Quarantined,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Lease {
    pub lease: String,
    pub slot: u32,
    pub tap: String,
    pub mac: String,
    pub host_mac: Option<String>,
    pub address: Ipv4Addr,
    pub gateway: Ipv4Addr,
    pub instance: String,
    pub owner_uid: u32,
    pub owner_pid: i32,
    pub owner_starttime: u64,
    pub execution_id: String,
    pub phase: Phase,
}

impl Lease {
    fn validate(&self) -> Result<()> {
        ensure!(valid_token(&self.lease), "invalid journal lease token");
        ensure!(
            self.slot < 16384 && self.tap == format!("{}{:04x}", host::TAP_PREFIX, self.slot),
            "invalid journal TAP name"
        );
        ensure!(
            host::valid_mac(&self.mac) && self.mac.starts_with("02:"),
            "invalid journal guest MAC"
        );
        ensure!(
            self.host_mac.as_deref().is_none_or(host::valid_mac),
            "invalid journal host MAC"
        );
        ensure!(
            u32::from(self.gateway) & 3 == 1
                && u32::from(self.address) == u32::from(self.gateway) + 1,
            "invalid journal /30 addresses"
        );
        ensure!(
            self.address.is_private() && self.gateway.is_private(),
            "journal addresses must be RFC1918"
        );
        ensure!(valid_unit(&self.instance), "invalid journal instance");
        ensure!(
            self.owner_pid > 0 && self.owner_starttime > 0,
            "invalid journal peer identity"
        );
        validate_execution(&self.execution_id)
    }

    fn require_owner(&self, owner: &Owner) -> Result<()> {
        ensure!(
            self.instance == owner.instance
                && self.owner_uid == owner.peer.uid
                && self.owner_pid == owner.peer.pid
                && self.owner_starttime == owner.starttime,
            "lease belongs to another owner"
        );
        Ok(())
    }
}

pub(super) fn valid_token(token: &str) -> bool {
    token.len() == 32
        && token
            .bytes()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}

fn validate_execution(execution: &str) -> Result<()> {
    ensure!(
        !execution.is_empty() && execution.len() <= 256,
        "execution_id must contain 1 through 256 bytes"
    );
    Ok(())
}

fn secure_path(path: &Path) -> Result<()> {
    ensure!(path.is_absolute(), "path must be absolute");
    for ancestor in path.ancestors() {
        let metadata = fs::symlink_metadata(ancestor)
            .with_context(|| format!("inspect {}", ancestor.display()))?;
        ensure!(
            !metadata.file_type().is_symlink()
                && metadata.uid() == 0
                && (metadata.mode() & 0o022 == 0
                    || (metadata.is_dir() && metadata.mode() & 0o1000 != 0)),
            "{} must be root-owned, non-symlink and protected against entry replacement",
            ancestor.display()
        );
    }
    Ok(())
}

fn open_secure(path: &Path) -> Result<File> {
    secure_path(path)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
        .open(path)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file() && metadata.uid() == 0 && metadata.mode() & 0o022 == 0,
        "untrusted regular file {}",
        path.display()
    );
    Ok(file)
}

fn create_private_directory(path: &Path) -> Result<()> {
    let ancestor = path
        .ancestors()
        .find(|ancestor| ancestor.exists())
        .context("directory has no existing ancestor")?;
    secure_path(ancestor)?;
    DirBuilder::new().recursive(true).mode(0o700).create(path)?;
    secure_path(path)?;
    let metadata = fs::metadata(path)?;
    ensure!(
        metadata.is_dir() && metadata.mode() & 0o077 == 0,
        "state directory must be private (0700)"
    );
    Ok(())
}

fn lock_file(path: &Path, nonblocking: bool) -> Result<Option<File>> {
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
        .open(path)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file() && metadata.uid() == 0 && metadata.mode() & 0o077 == 0,
        "untrusted lock file"
    );
    flock(file, nonblocking)
}

fn flock(file: File, nonblocking: bool) -> Result<Option<File>> {
    let operation = if nonblocking {
        rustix::fs::FlockOperation::NonBlockingLockExclusive
    } else {
        rustix::fs::FlockOperation::LockExclusive
    };
    match rustix::fs::flock(&file, operation) {
        Ok(()) => Ok(Some(file)),
        Err(rustix::io::Errno::WOULDBLOCK) if nonblocking => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn process_starttime(pid: i32) -> Result<u64> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat"))?;
    let (_, fields) = stat.rsplit_once(')').context("invalid process stat")?;
    fields
        .split_whitespace()
        .nth(19)
        .context("missing process starttime")?
        .parse()
        .context("invalid process starttime")
}

fn cgroup_instance(cgroup: &str, units: &[String]) -> Result<String> {
    let mut found = None;
    for line in cgroup.lines() {
        let mut fields = line.splitn(3, ':');
        let hierarchy = fields.next();
        let controllers = fields.next();
        let path = fields.next().context("invalid process cgroup")?;
        if hierarchy != Some("0") || controllers != Some("") {
            continue;
        }
        let mut components = path.split('/');
        if components.next() != Some("") || components.next() != Some("system.slice") {
            continue;
        }
        if let Some(unit) = components
            .next()
            .filter(|unit| units.iter().any(|configured| configured == unit))
        {
            ensure!(found.is_none(), "ambiguous garden cgroup");
            found = Some(unit.to_owned());
        }
    }
    found.context("peer does not belong to a configured garden system service")
}

struct Owner {
    instance: String,
    peer: PeerCredentials,
    starttime: u64,
}

impl Owner {
    fn authenticate(policy: &Policy, peer: PeerCredentials) -> Result<Self> {
        let starttime = process_starttime(peer.pid)?;
        let status = fs::read_to_string(format!("/proc/{}/status", peer.pid))?;
        let uid = status
            .lines()
            .find_map(|line| line.strip_prefix("Uid:\t"))
            .context("missing process UID")?
            .split_whitespace()
            .next()
            .context("missing process UID")?
            .parse::<u32>()?;
        ensure!(uid == peer.uid, "peer process identity changed");
        let cgroup = fs::read_to_string(format!("/proc/{}/cgroup", peer.pid))?;
        let instance = cgroup_instance(&cgroup, &policy.garden_units)?;
        ensure!(
            process_starttime(peer.pid)? == starttime,
            "peer process identity changed"
        );
        Ok(Self {
            instance,
            peer,
            starttime,
        })
    }
}

struct Store {
    policy: Policy,
    instance: String,
    directory: PathBuf,
}

impl Store {
    fn policy(path: &Path) -> Result<Policy> {
        ensure!(
            rustix::process::geteuid().is_root(),
            "network operations require root"
        );
        Policy::validate(serde_json::from_reader::<_, PolicyFile>(open_secure(
            path,
        )?)?)
    }

    fn open(policy: Policy, instance: String) -> Result<Self> {
        ensure!(
            policy.garden_units.contains(&instance),
            "instance is not a configured garden service"
        );
        create_private_directory(&policy.state_directory)?;
        let directory = policy.state_directory.join(&instance);
        create_private_directory(&directory)?;
        Ok(Self {
            policy,
            instance,
            directory,
        })
    }

    fn global_lock(&self) -> Result<File> {
        let directory = Path::new("/run/sower-network-ownership");
        create_private_directory(directory)?;
        lock_file(&directory.join("namespace.lock"), false)?.context("allocation lock unavailable")
    }

    fn execution_lock(&self, execution: &str, nonblocking: bool) -> Result<Option<File>> {
        // Bound lock-file growth without unlinking inodes that other requests may hold.
        let hash = Sha256::digest(execution.as_bytes());
        let bucket = u16::from_be_bytes([hash[0], hash[1]]) & 0x3fff;
        lock_file(
            &self.directory.join(format!("execution-{bucket:04x}.lock")),
            nonblocking,
        )
    }

    fn records_in(&self, directory: &Path) -> Result<Vec<Lease>> {
        if !directory.exists() {
            return Ok(Vec::new());
        }
        secure_path(directory)?;
        let mut leases = Vec::new();
        for entry in fs::read_dir(directory)? {
            let path = entry?.path();
            if path.extension().is_none_or(|extension| extension != "json") {
                continue;
            }
            let lease: Lease =
                serde_json::from_reader(open_secure(&path)?).context("read allocation journal")?;
            lease.validate()?;
            ensure!(
                path.file_stem().and_then(|name| name.to_str()) == Some(lease.lease.as_str())
                    && directory.file_name().and_then(|name| name.to_str())
                        == Some(lease.instance.as_str()),
                "journal filename or instance mismatch"
            );
            leases.push(lease);
        }
        Ok(leases)
    }

    fn all_records(&self) -> Result<Vec<Lease>> {
        let mut leases = Vec::new();
        for unit in &self.policy.garden_units {
            leases.extend(self.records_in(&self.policy.state_directory.join(unit))?);
        }
        let mut slots = BTreeSet::new();
        for lease in &leases {
            ensure!(
                slots.insert(lease.slot),
                "duplicate journal allocation slot"
            );
        }
        Ok(leases)
    }

    fn load(&self, token: &str) -> Result<Option<Lease>> {
        ensure!(valid_token(token), "invalid lease token");
        let path = self.directory.join(format!("{token}.json"));
        if !path.exists() {
            return Ok(None);
        }
        let lease: Lease = serde_json::from_reader(open_secure(&path)?)?;
        lease.validate()?;
        ensure!(
            lease.lease == token && lease.instance == self.instance,
            "journal ownership mismatch"
        );
        Ok(Some(lease))
    }

    fn save(&self, lease: &Lease) -> Result<()> {
        let temporary = self.directory.join(format!("{}.tmp", lease.lease));
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
            .open(&temporary)?;
        serde_json::to_writer(&mut file, lease)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(
            temporary,
            self.directory.join(format!("{}.json", lease.lease)),
        )?;
        File::open(&self.directory)?.sync_all()?;
        Ok(())
    }

    fn output(&self, lease: &Lease) -> Result<String> {
        Ok(serde_json::to_string(&serde_json::json!({
            "lease": lease.lease, "tap": lease.tap, "mac": lease.mac,
            "address": format!("{}/30", lease.address), "gateway": lease.gateway, "dns": self.policy.dns,
        }))?)
    }

    fn reserve(&self, owner: &Owner, execution: &str) -> Result<Lease> {
        let _global = self.global_lock()?;
        ensure!(
            process_starttime(owner.peer.pid).is_ok_and(|start| start == owner.starttime),
            "garden owner exited before allocation"
        );
        let leases = self.all_records()?;
        ensure!(
            !leases
                .iter()
                .any(|lease| lease.instance == self.instance && lease.execution_id == execution),
            "execution already has an allocation"
        );
        let occupied: BTreeSet<_> = leases.iter().map(|lease| lease.slot).collect();
        let slot = (0..self.policy.slots())
            .find(|slot| !occupied.contains(slot))
            .context("network address pool exhausted (including quarantined allocations)")?;
        let (gateway, address) = self.policy.addresses(slot)?;
        let mut random = [0u8; 16];
        File::open("/dev/urandom")?.read_exact(&mut random)?;
        let mut token = String::with_capacity(32);
        for byte in random {
            use std::fmt::Write as _;
            write!(&mut token, "{byte:02x}")?;
        }
        ensure!(
            !leases.iter().any(|lease| lease.lease == token),
            "lease identifier collision"
        );
        let lease = Lease {
            lease: token,
            slot,
            tap: format!("{}{:04x}", host::TAP_PREFIX, slot),
            mac: format!(
                "02:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
                random[0], random[1], random[2], random[3], random[4]
            ),
            host_mac: None,
            address,
            gateway,
            instance: self.instance.clone(),
            owner_uid: owner.peer.uid,
            owner_pid: owner.peer.pid,
            owner_starttime: owner.starttime,
            execution_id: execution.to_owned(),
            phase: Phase::Reserved,
        };
        self.save(&lease)?;
        Ok(lease)
    }

    fn provision(&self, owner: &Owner, execution: &str) -> Result<String> {
        validate_execution(execution)?;
        let _execution = self
            .execution_lock(execution, false)?
            .context("execution lock unavailable")?;
        let existing = {
            let _global = self.global_lock()?;
            self.records_in(&self.directory)?
                .into_iter()
                .find(|lease| lease.execution_id == execution)
        };
        if let Some(lease) = existing {
            lease.require_owner(owner)?;
            ensure!(
                lease.phase == Phase::Active,
                "execution has an incomplete allocation; cleanup required"
            );
            return self.output(&lease);
        }
        let mut lease = self.reserve(owner, execution)?;
        let setup = (|| -> Result<()> {
            host::require_available_subnet(lease.gateway)?;
            ensure!(
                !host::links()?
                    .iter()
                    .any(|link| link["ifname"] == lease.tap),
                "interface name is already occupied"
            );
            lease.phase = Phase::Allocated;
            self.save(&lease)?;
            host::install_guard(&self.policy, std::iter::once(&lease))?;
            host::purge_connections(&lease)?;
            host::create_tap(&mut lease)?;
            self.save(&lease)?;
            host::install_ingress(&lease)?;
            lease.phase = Phase::Active;
            self.save(&lease)?;
            host::install_guard(&self.policy, std::iter::once(&lease))?;
            host::set_up(&lease)?;
            Ok(())
        })();
        if let Err(error) = setup {
            if let Err(cleanup) = self
                .revoke(&mut lease)
                .and_then(|()| self.release(&mut lease))
            {
                tracing::error!(lease = lease.lease, %cleanup, "failed provision retained for cleanup");
            }
            return Err(error.context("network provisioning failed"));
        }
        self.output(&lease)
    }

    fn revoke(&self, lease: &mut Lease) -> Result<()> {
        if lease.phase == Phase::Reserved {
            return Ok(());
        }
        lease.phase = Phase::Revoked;
        let save = self.save(lease);
        let down = host::set_down(lease);
        let guard = host::install_guard(&self.policy, std::iter::once(&*lease));
        save?;
        down?;
        guard?;
        Ok(())
    }

    fn release(&self, lease: &mut Lease) -> Result<()> {
        ensure!(
            lease.phase == Phase::Reserved || lease.phase == Phase::Revoked,
            "lease must be revoked before release"
        );
        if lease.phase != Phase::Reserved
            && let Err(error) = host::remove_resources(lease)
        {
            lease.phase = Phase::Quarantined;
            self.save(lease)?;
            return Err(error);
        }
        let _global = self.global_lock()?;
        fs::remove_file(self.directory.join(format!("{}.json", lease.lease)))?;
        let temporary = self.directory.join(format!("{}.tmp", lease.lease));
        if temporary.exists() {
            fs::remove_file(temporary)?;
        }
        File::open(&self.directory)?.sync_all()?;
        Ok(())
    }

    fn operate(&self, owner: &Owner, token: &str, release: bool) -> Result<()> {
        let lease = {
            let _global = self.global_lock()?;
            self.load(token)?
        };
        let Some(lease) = lease else {
            return Ok(());
        };
        lease.require_owner(owner)?;
        let _execution = self
            .execution_lock(&lease.execution_id, false)?
            .context("execution lock unavailable")?;
        let lease = {
            let _global = self.global_lock()?;
            self.load(token)?
        };
        let Some(mut lease) = lease else {
            return Ok(());
        };
        lease.require_owner(owner)?;
        if release {
            ensure!(
                matches!(
                    lease.phase,
                    Phase::Reserved | Phase::Revoked | Phase::Quarantined
                ),
                "lease must be revoked before release"
            );
            self.revoke(&mut lease)?;
            self.release(&mut lease)
        } else {
            self.revoke(&mut lease)
        }
    }

    fn cleanup(&self, root_hook: bool) -> Result<()> {
        let leases = {
            let _global = self.global_lock()?;
            self.records_in(&self.directory)?
        };
        let mut failures = Vec::new();
        for lease in leases {
            let Some(_execution) = self.execution_lock(&lease.execution_id, true)? else {
                if root_hook {
                    failures.push(format!("{}: operation is active", lease.lease));
                }
                continue;
            };
            let lease = {
                let _global = self.global_lock()?;
                self.load(&lease.lease)?
            };
            let Some(mut lease) = lease else {
                continue;
            };
            if !root_hook
                && lease.phase == Phase::Active
                && process_starttime(lease.owner_pid)
                    .is_ok_and(|start| start == lease.owner_starttime)
            {
                continue;
            }
            if let Err(error) = self
                .revoke(&mut lease)
                .and_then(|()| self.release(&mut lease))
            {
                failures.push(format!("{}: {error:#}", lease.lease));
            }
        }
        ensure!(
            failures.is_empty(),
            "network cleanup incomplete: {}",
            failures.join("; ")
        );
        Ok(())
    }
}

pub(super) fn request(
    policy_path: &Path,
    peer: PeerCredentials,
    request: &Request,
) -> Result<Option<String>> {
    let policy = Store::policy(policy_path)?;
    let owner = Owner::authenticate(&policy, peer)?;
    let store = Store::open(policy, owner.instance.clone())?;
    match request
        .network_action
        .as_deref()
        .context("missing network_action")?
    {
        "provision" => {
            ensure!(request.lease.is_none(), "provision does not accept lease");
            Ok(Some(
                store.provision(
                    &owner,
                    request
                        .execution_id
                        .as_deref()
                        .context("missing execution_id")?,
                )?,
            ))
        }
        "revoke" | "release" => {
            ensure!(
                request.execution_id.is_none(),
                "lease operation does not accept execution_id"
            );
            store.operate(
                &owner,
                request.lease.as_deref().context("missing lease")?,
                request.network_action.as_deref() == Some("release"),
            )?;
            Ok(None)
        }
        "cleanup" => {
            ensure!(
                request.execution_id.is_none() && request.lease.is_none(),
                "cleanup does not accept execution_id or lease"
            );
            store.cleanup(false)?;
            Ok(None)
        }
        action => bail!("invalid network_action: {action}"),
    }
}

pub(super) fn cleanup(policy_path: &Path, instance: &str) -> Result<()> {
    ensure!(
        rustix::process::getuid().is_root() && rustix::process::geteuid().is_root(),
        "network cleanup requires direct root invocation"
    );
    Store::open(Store::policy(policy_path)?, instance.to_owned())?.cleanup(true)
}

#[cfg(test)]
pub(super) fn test_lease() -> Lease {
    Lease {
        lease: "a".repeat(32),
        slot: 0,
        tap: "swnt0000".into(),
        mac: "02:00:00:00:00:01".into(),
        host_mac: Some("02:00:00:00:00:02".into()),
        address: "10.254.0.2".parse().unwrap(),
        gateway: "10.254.0.1".parse().unwrap(),
        instance: "sower-garden.service".into(),
        owner_uid: 1000,
        owner_pid: 123,
        owner_starttime: 456,
        execution_id: "opaque/../execution".into(),
        phase: Phase::Active,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owner_identity_includes_instance_pid_starttime_and_uid() {
        let lease = test_lease();
        let mut owner = Owner {
            instance: lease.instance.clone(),
            peer: PeerCredentials {
                pid: lease.owner_pid,
                uid: lease.owner_uid,
                gid: 1000,
            },
            starttime: lease.owner_starttime,
        };
        assert!(lease.require_owner(&owner).is_ok());
        owner.starttime += 1;
        assert!(lease.require_owner(&owner).is_err());
        owner.starttime = lease.owner_starttime;
        owner.peer.pid += 1;
        assert!(lease.require_owner(&owner).is_err());
        owner.peer.pid = lease.owner_pid;
        owner.peer.uid += 1;
        assert!(lease.require_owner(&owner).is_err());
        owner.peer.uid = lease.owner_uid;
        owner.instance = "other.service".into();
        assert!(lease.require_owner(&owner).is_err());
    }

    #[test]
    fn system_service_cgroup_must_match_configured_unit() {
        let units = vec!["sower-garden.service".into()];
        assert_eq!(
            cgroup_instance("0::/system.slice/sower-garden.service/vmm", &units).unwrap(),
            "sower-garden.service"
        );
        for path in [
            "0::/user.slice/system.slice/sower-garden.service",
            "0::/system.slice/untrusted.service",
            "0::/system.slice/sower-garden.service-extra",
            "1:name=systemd:/system.slice/sower-garden.service",
        ] {
            assert!(cgroup_instance(path, &units).is_err(), "{path}");
        }
    }

    #[test]
    fn journal_rejects_untrusted_packet_identity() {
        let mut lease = test_lease();
        assert!(lease.validate().is_ok());
        lease.tap = "eth0".into();
        assert!(lease.validate().is_err());
        lease = test_lease();
        lease.lease = "../operator-file".into();
        assert!(lease.validate().is_err());
        lease = test_lease();
        lease.mac = "02:00:00:00:00:01; accept".into();
        assert!(lease.validate().is_err());
    }

    #[test]
    fn execution_lock_excludes_other_processes_until_operation_finishes() {
        if let Some(path) = std::env::var_os("SOWER_TEST_EXECUTION_LOCK") {
            let file = OpenOptions::new()
                .read(true)
                .write(true)
                .open(path)
                .unwrap();
            let acquired = flock(file, true).unwrap().is_some();
            assert_eq!(
                acquired,
                std::env::var("SOWER_TEST_LOCK_AVAILABLE").unwrap() == "true"
            );
            return;
        }
        let directory = std::env::temp_dir().join(format!(
            "sower-network-lock-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("execution.lock");
        let file = OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let locked = flock(file, false).unwrap().unwrap();
        let probe = |available: bool| {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "execution_lock_excludes_other_processes_until_operation_finishes",
                    "--nocapture",
                ])
                .env("SOWER_TEST_EXECUTION_LOCK", &path)
                .env("SOWER_TEST_LOCK_AVAILABLE", available.to_string())
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stdout)
            );
        };
        probe(false);
        drop(locked);
        probe(true);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn failed_journal_update_preserves_reserved_allocation() {
        let directory = std::env::temp_dir().join(format!(
            "sower-network-journal-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&directory).unwrap();
        let policy = Policy::validate(
            serde_json::from_value::<PolicyFile>(serde_json::json!({
                "address_pool": "10.254.0.0/16", "dns_resolver": "1.1.1.1",
                "state_directory": directory,
            }))
            .unwrap(),
        )
        .unwrap();
        let store = Store {
            policy,
            instance: "sower-garden.service".into(),
            directory: directory.clone(),
        };
        let mut lease = test_lease();
        lease.phase = Phase::Allocated;
        store.save(&lease).unwrap();
        let temporary = directory.join(format!("{}.tmp", lease.lease));
        let unrelated = directory.join("unrelated");
        fs::write(&unrelated, b"untouched").unwrap();
        std::os::unix::fs::symlink(&unrelated, &temporary).unwrap();
        lease.phase = Phase::Active;
        assert!(store.save(&lease).is_err());
        let persisted: Lease = serde_json::from_reader(
            File::open(directory.join(format!("{}.json", lease.lease))).unwrap(),
        )
        .unwrap();
        assert_eq!(persisted.phase, Phase::Allocated);
        assert_eq!(persisted.slot, lease.slot);
        assert_eq!(fs::read(&unrelated).unwrap(), b"untouched");
        fs::remove_file(temporary).unwrap();
        lease.phase = Phase::Revoked;
        store.save(&lease).unwrap();
        let persisted: Lease = serde_json::from_reader(
            File::open(directory.join(format!("{}.json", lease.lease))).unwrap(),
        )
        .unwrap();
        assert_eq!(persisted.phase, Phase::Revoked);
        fs::remove_dir_all(directory).unwrap();
    }
}
