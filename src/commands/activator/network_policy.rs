use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::net::Ipv4Addr;
use std::path::PathBuf;
use std::str::FromStr;

// Conservative IANA special-purpose exclusions, including deprecated allocations.
// The operator may extend, but cannot weaken, this list.
pub(super) const SPECIAL: &[&str] = &[
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.31.196.0/24",
    "192.52.193.0/24",
    "192.175.48.0/24",
    "192.88.99.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0/4",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Subnet {
    pub network: u32,
    pub prefix: u8,
}

impl FromStr for Subnet {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        let (address, prefix) = value.split_once('/').context("expected IPv4 CIDR")?;
        let prefix: u8 = prefix.parse().context("invalid IPv4 prefix")?;
        ensure!(prefix <= 32, "invalid IPv4 prefix");
        let network = u32::from(
            address
                .parse::<Ipv4Addr>()
                .context("invalid IPv4 address")?,
        );
        let mask = u32::MAX.checked_shl(u32::from(32 - prefix)).unwrap_or(0);
        ensure!(
            network & mask == network,
            "CIDR must use its network address"
        );
        Ok(Self { network, prefix })
    }
}

impl Subnet {
    pub fn contains(self, address: Ipv4Addr) -> bool {
        let mask = u32::MAX
            .checked_shl(u32::from(32 - self.prefix))
            .unwrap_or(0);
        u32::from(address) & mask == self.network
    }

    pub fn canonical(self) -> String {
        format!("{}/{}", Ipv4Addr::from(self.network), self.prefix)
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct PolicyFile {
    pub address_pool: String,
    pub dns_resolver: Ipv4Addr,
    #[serde(default)]
    pub protected_destinations: Vec<String>,
    #[serde(default = "default_state_directory")]
    pub state_directory: PathBuf,
    #[serde(default = "default_garden_units")]
    pub garden_units: Vec<String>,
}

fn default_state_directory() -> PathBuf {
    "/run/sower-network".into()
}

fn default_garden_units() -> Vec<String> {
    vec!["sower-garden.service".into()]
}

pub(super) fn valid_unit(unit: &str) -> bool {
    unit.ends_with(".service")
        && unit.len() <= 255
        && unit.len() > ".service".len()
        && unit
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_.@:-\\x".contains(&byte))
}

pub(super) struct Policy {
    pub pool: Subnet,
    pub dns: Ipv4Addr,
    pub protected: Vec<Subnet>,
    pub state_directory: PathBuf,
    pub garden_units: Vec<String>,
}

impl Policy {
    pub fn validate(file: PolicyFile) -> Result<Self> {
        ensure!(
            !file.garden_units.is_empty() && file.garden_units.iter().all(|unit| valid_unit(unit)),
            "garden_units must contain configured system service names"
        );
        let pool: Subnet = file.address_pool.parse()?;
        ensure!(
            (16..=30).contains(&pool.prefix),
            "address pool must have prefix /16 through /30"
        );
        let private = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"];
        ensure!(
            private.iter().any(|cidr| {
                let subnet: Subnet = cidr.parse().expect("constant CIDR");
                subnet.contains(Ipv4Addr::from(pool.network)) && pool.prefix >= subnet.prefix
            }),
            "address pool must be contained in an RFC1918 network"
        );
        let mut protected = SPECIAL
            .iter()
            .map(|cidr| cidr.parse())
            .collect::<Result<Vec<Subnet>>>()?;
        for cidr in file.protected_destinations {
            protected.push(cidr.parse().context("invalid protected destination")?);
        }
        ensure!(
            !protected
                .iter()
                .any(|subnet| subnet.contains(file.dns_resolver)),
            "DNS resolver must be public and outside protected destinations"
        );
        ensure!(
            file.state_directory.is_absolute(),
            "state directory must be absolute"
        );
        if file
            .state_directory
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
        {
            bail!("state directory must not contain parent traversal");
        }
        Ok(Self {
            pool,
            dns: file.dns_resolver,
            protected,
            state_directory: file.state_directory,
            garden_units: file.garden_units,
        })
    }

    pub fn slots(&self) -> u32 {
        1 << (30 - self.pool.prefix)
    }

    pub fn addresses(&self, slot: u32) -> Result<(Ipv4Addr, Ipv4Addr)> {
        ensure!(slot < self.slots(), "allocation outside address pool");
        let base = self.pool.network + slot * 4;
        Ok((Ipv4Addr::from(base + 1), Ipv4Addr::from(base + 2)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file() -> PolicyFile {
        PolicyFile {
            address_pool: "10.254.0.0/16".into(),
            dns_resolver: Ipv4Addr::new(1, 1, 1, 1),
            protected_destinations: vec![],
            state_directory: "/run/sower-network".into(),
            garden_units: default_garden_units(),
        }
    }

    #[test]
    fn rejects_special_and_operator_protected_resolvers() {
        for address in [
            "127.0.0.1",
            "169.254.169.254",
            "100.100.100.100",
            "192.168.1.1",
            "224.0.0.1",
            "240.0.0.1",
        ] {
            let mut file = file();
            file.dns_resolver = address.parse().unwrap();
            assert!(Policy::validate(file).is_err(), "{address}");
        }
        let mut file = file();
        file.protected_destinations.push("1.1.1.0/24".into());
        assert!(Policy::validate(file).is_err());
    }

    #[test]
    fn allocation_has_disjoint_bounded_point_to_point_subnets() {
        let policy = Policy::validate(file()).unwrap();
        assert_eq!(
            policy.addresses(0).unwrap(),
            ("10.254.0.1".parse().unwrap(), "10.254.0.2".parse().unwrap())
        );
        assert_eq!(
            policy.addresses(16383).unwrap(),
            (
                "10.254.255.253".parse().unwrap(),
                "10.254.255.254".parse().unwrap()
            )
        );
        assert!(policy.addresses(16384).is_err());
        let mut file = file();
        file.address_pool = "10.254.0.4/30".into();
        let policy = Policy::validate(file).unwrap();
        assert_eq!(policy.slots(), 1);
        assert!(policy.addresses(1).is_err());
    }

    #[test]
    fn rejects_noncanonical_or_public_pools_and_firewall_injection() {
        for pool in [
            "10.254.0.1/16",
            "8.8.8.0/24",
            "10.0.0.0/8",
            "10.0.0.0/33",
            "10.0.0.0/24; accept",
        ] {
            let mut file = file();
            file.address_pool = pool.into();
            assert!(Policy::validate(file).is_err(), "{pool}");
        }
        let mut file = file();
        file.protected_destinations
            .push("8.8.8.8/32; accept".into());
        assert!(Policy::validate(file).is_err());
    }
}
