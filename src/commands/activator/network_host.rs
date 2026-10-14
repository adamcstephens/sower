use anyhow::{Context, Result, ensure};
use serde_json::Value;
use std::io::Write;
use std::net::Ipv4Addr;
use std::process::{Command, Stdio};

use super::network::{Lease, Phase, valid_token};
use super::network_policy::{Policy, Subnet};

pub(super) const MARKER: &str = "sower-network";
pub(super) const TAP_PREFIX: &str = "swnt";

pub(super) fn command(program: &str, args: &[&str]) -> Result<String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("run {program}"))?;
    ensure!(
        output.status.success(),
        "{program} failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    String::from_utf8(output.stdout).with_context(|| format!("{program} emitted non-UTF8 output"))
}

fn nft(script: &str) -> Result<()> {
    let mut child = Command::new("nft")
        .args(["--file", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .context("run nft")?;
    let write_result = child
        .stdin
        .take()
        .context("nft stdin")?
        .write_all(script.as_bytes());
    let output = child.wait_with_output().context("wait for nft")?;
    write_result.context("write nft transaction")?;
    ensure!(
        output.status.success(),
        "nft failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(())
}

fn table_exists(family: &str, name: &str) -> Result<bool> {
    let tables: Value = serde_json::from_str(&command("nft", &["--json", "list", "tables"])?)?;
    let exists = tables["nftables"]
        .as_array()
        .context("nft table listing")?
        .iter()
        .any(|entry| entry["table"]["family"] == family && entry["table"]["name"] == name);
    if exists {
        let table: Value =
            serde_json::from_str(&command("nft", &["--json", "list", "table", family, name])?)?;
        let owned = table["nftables"]
            .as_array()
            .context("nft table details")?
            .iter()
            .any(|entry| {
                entry["table"]["family"] == family
                    && entry["table"]["name"] == name
                    && entry["table"]["comment"] == MARKER
            });
        ensure!(
            owned,
            "refusing to change unowned nft table {family} {name}"
        );
    }
    Ok(exists)
}

pub(super) fn inet_table(lease: &Lease) -> String {
    format!("sower_network_{}", lease.lease)
}

pub(super) fn netdev_table(lease: &Lease) -> String {
    format!("sower_netdev_{}", lease.lease)
}

pub(super) fn install_guard<'a>(
    policy: &Policy,
    mut leases: impl Iterator<Item = &'a Lease>,
) -> Result<()> {
    let lease = leases
        .next()
        .context("guard requires one execution lease")?;
    ensure!(
        leases.next().is_none(),
        "guard can only change one execution"
    );
    ensure!(valid_token(&lease.lease), "invalid execution lease token");
    let table = inet_table(lease);
    let exists = table_exists("inet", &table)?;
    nft(&guard_script(policy, lease, exists))
}

fn guard_script(policy: &Policy, lease: &Lease, exists: bool) -> String {
    let table = inet_table(lease);
    let mut script = String::new();
    if exists {
        script.push_str(&format!("delete table inet {table}\n"));
    }
    script.push_str(&format!(
        "table inet {table} {{\n comment \"{MARKER}\";\n\
         set taps {{ type ifname; elements = {{ \"{}\" }}; }}\n",
        lease.tap
    ));
    script.push_str(" set blocked { type ipv4_addr; flags interval; auto-merge; elements = { ");
    for (index, subnet) in policy.protected.iter().enumerate() {
        if index != 0 {
            script.push_str(", ");
        }
        script.push_str(&subnet.canonical());
    }
    script.push_str(" }; }\n");
    // After IPv4 defragmentation (-400), before conntrack (-200) and DNAT
    // (-100). Mandatory original tuple/FIB denials cannot be widened by NAT.
    script.push_str(
        " chain original { type filter hook prerouting priority -310; policy accept;\n\
         iifname @taps meta nfproto ipv6 drop;\n\
         iifname @taps fib daddr type local drop;\n\
         iifname @taps ip daddr @blocked drop;\n",
    );
    if lease.phase == Phase::Active {
        script.push_str(&format!(
            " iifname \"{}\" ip saddr {} ip daddr {} udp dport 53 accept;\n\
             iifname \"{}\" ip saddr {} ip daddr {} tcp dport 53 accept;\n\
             iifname \"{}\" ip saddr {} tcp dport {{ 80, 443 }} accept;\n",
            lease.tap,
            lease.address,
            policy.dns,
            lease.tap,
            lease.address,
            policy.dns,
            lease.tap,
            lease.address,
        ));
    }
    script.push_str(" iifname @taps drop;\n }\n");
    script.push_str(
        " chain input { type filter hook input priority -50; policy accept; iifname @taps drop; }\n\
         chain output { type filter hook output priority -50; policy accept; oifname @taps drop; }\n\
         chain forward { type filter hook forward priority -50; policy accept;\n\
         iifname @taps oifname @taps drop;\n\
         iifname @taps meta nfproto ipv6 drop;\n\
         oifname @taps meta nfproto ipv6 drop;\n\
         iifname @taps fib daddr type local drop;\n\
         iifname @taps ip daddr @blocked drop;\n\
         oifname @taps ip saddr @blocked drop;\n"
    );
    if lease.phase == Phase::Active {
        let tap = &lease.tap;
        let address = lease.address;
        let dns = policy.dns;
        script.push_str(&format!(
            " iifname \"{tap}\" ip saddr {address} ip daddr {dns} udp dport 53 ct state {{ new, established }} accept;\n\
             iifname \"{tap}\" ip saddr {address} ip daddr {dns} tcp dport 53 ct state {{ new, established }} accept;\n\
             iifname \"{tap}\" ip saddr {address} tcp dport {{ 80, 443 }} ct state {{ new, established }} accept;\n\
             oifname \"{tap}\" ip daddr {address} ct state established ct status snat accept;\n"
        ));
    }
    script.push_str(" iifname @taps drop; oifname @taps drop;\n }\n");
    script.push_str(" chain nat { type nat hook postrouting priority srcnat; policy accept;\n");
    if lease.phase == Phase::Active {
        script.push_str(&format!(
            " iifname \"{}\" ip saddr {} masquerade;\n",
            lease.tap, lease.address
        ));
    }
    script.push_str(" }\n}\n");
    script
}

pub(super) fn require_available_subnet(gateway: Ipv4Addr) -> Result<()> {
    let routes: Vec<Value> = serde_json::from_str(&command(
        "ip",
        &["--json", "-family", "inet", "route", "show", "table", "all"],
    )?)?;
    check_routes(gateway, &routes)
}

fn check_routes(gateway: Ipv4Addr, routes: &[Value]) -> Result<()> {
    let network = u32::from(gateway) & !3;
    for route in routes {
        let destination = route["dst"].as_str().context("route lacks destination")?;
        if destination == "default" {
            continue;
        }
        let subnet = if destination.contains('/') {
            destination.parse::<Subnet>()?
        } else {
            Subnet {
                network: u32::from(destination.parse::<Ipv4Addr>()?),
                prefix: 32,
            }
        };
        ensure!(
            subnet.prefix == 0
                || (!subnet.contains(Ipv4Addr::from(network))
                    && !(network..network + 4).contains(&subnet.network)),
            "execution subnet {}/30 overlaps existing host route {destination}",
            Ipv4Addr::from(network)
        );
    }
    Ok(())
}

pub(super) fn links() -> Result<Vec<Value>> {
    serde_json::from_str(&command("ip", &["--json", "link", "show"])?)
        .context("parse interface listing")
}

pub(super) fn owned_link<'a>(lease: &Lease, links: &'a [Value]) -> Result<Option<&'a Value>> {
    let Some(link) = links.iter().find(|link| link["ifname"] == lease.tap) else {
        return Ok(None);
    };
    ensure!(
        link["ifalias"] == format!("{MARKER}:{}", lease.lease),
        "refusing to change unowned interface {}",
        lease.tap
    );
    Ok(Some(link))
}

pub(super) fn create_tap(lease: &mut Lease) -> Result<()> {
    ensure!(
        !links()?.iter().any(|link| link["ifname"] == lease.tap),
        "interface name is already occupied"
    );
    let uid = lease.owner_uid.to_string();
    command(
        "ip",
        &[
            "tuntap", "add", "dev", &lease.tap, "mode", "tap", "user", &uid, "vnet_hdr",
        ],
    )?;
    command(
        "ip",
        &[
            "link",
            "set",
            "dev",
            &lease.tap,
            "alias",
            &format!("{MARKER}:{}", lease.lease),
        ],
    )?;
    // udev can replace the initial TAP MAC while applying its link policy.
    command(
        "udevadm",
        &[
            "wait",
            "--initialized=true",
            "--timeout=3",
            &format!("/sys/class/net/{}", lease.tap),
        ],
    )?;
    let links = links()?;
    let link = owned_link(lease, &links)?.context("created TAP disappeared")?;
    let mac = link["address"]
        .as_str()
        .context("TAP lacks Ethernet address")?;
    ensure!(valid_mac(mac), "TAP has an invalid Ethernet address");
    lease.host_mac = Some(mac.to_owned());
    command(
        "ip",
        &[
            "address",
            "add",
            &format!("{}/30", lease.gateway),
            "dev",
            &lease.tap,
        ],
    )?;
    Ok(())
}

pub(super) fn valid_mac(mac: &str) -> bool {
    mac.len() == 17
        && mac.split(':').count() == 6
        && mac.split(':').all(|byte| {
            byte.len() == 2
                && byte
                    .bytes()
                    .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        })
}

pub(super) fn install_ingress(lease: &Lease) -> Result<()> {
    let table = netdev_table(lease);
    let exists = table_exists("netdev", &table)?;
    let host_mac = lease.host_mac.as_deref().context("missing TAP MAC")?;
    let mut script = String::new();
    if exists {
        script.push_str(&format!("delete table netdev {table}\n"));
    }
    script.push_str(&format!(
        "table netdev {table} {{\n comment \"{MARKER}\";\n\
         chain ingress {{ type filter hook ingress device \"{}\" priority -500; policy drop;\n\
         ether saddr {} ether daddr {host_mac} ether type ip ip saddr {} accept;\n\
         ether saddr {} ether daddr {{ ff:ff:ff:ff:ff:ff, {host_mac} }} ether type arp arp operation request arp saddr ether {} arp saddr ip {} arp daddr ether 00:00:00:00:00:00 arp daddr ip {} accept;\n\
         ether saddr {} ether daddr {host_mac} ether type arp arp operation reply arp saddr ether {} arp saddr ip {} arp daddr ether {host_mac} arp daddr ip {} accept;\n\
         }}\n}}\n",
        lease.tap, lease.mac, lease.address,
        lease.mac, lease.mac, lease.address, lease.gateway,
        lease.mac, lease.mac, lease.address, lease.gateway,
    ));
    nft(&script)
}

pub(super) fn set_up(lease: &Lease) -> Result<()> {
    owned_link(lease, &links()?)?.context("TAP disappeared")?;
    command("ip", &["link", "set", "dev", &lease.tap, "up"])?;
    Ok(())
}

pub(super) fn set_down(lease: &Lease) -> Result<()> {
    if owned_link(lease, &links()?)?.is_some() {
        command("ip", &["link", "set", "dev", &lease.tap, "down"])?;
    }
    Ok(())
}

pub(super) fn purge_connections(lease: &Lease) -> Result<()> {
    let address = lease.address.to_string();
    // Check before and after instead of treating conntrack's ambiguous exit 1
    // (both 'no entries' and failures) as successful cleanup.
    for selector in ["--orig-src", "--orig-dst", "--reply-src", "--reply-dst"] {
        if !command(
            "conntrack",
            &["--dump", "--family", "ipv4", selector, &address],
        )?
        .trim()
        .is_empty()
        {
            command(
                "conntrack",
                &["--delete", "--family", "ipv4", selector, &address],
            )?;
        }
        ensure!(
            command(
                "conntrack",
                &["--dump", "--family", "ipv4", selector, &address]
            )?
            .trim()
            .is_empty(),
            "stale conntrack entries for {address}"
        );
    }
    Ok(())
}

pub(super) fn remove_resources(lease: &Lease) -> Result<()> {
    set_down(lease)?;
    if owned_link(lease, &links()?)?.is_some() {
        command("ip", &["tuntap", "del", "dev", &lease.tap, "mode", "tap"])?;
        ensure!(
            owned_link(lease, &links()?)?.is_none(),
            "TAP remains attached; allocation quarantined"
        );
    }
    purge_connections(lease)?;
    let mut script = String::new();
    for (family, table) in [("inet", inet_table(lease)), ("netdev", netdev_table(lease))] {
        if table_exists(family, &table)? {
            script.push_str(&format!("delete table {family} {table}\n"));
        }
    }
    if !script.is_empty() {
        nft(&script)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::network::test_lease;
    use super::*;

    #[test]
    fn rejects_routes_whose_forwarding_would_be_replaced_by_the_execution_subnet() {
        let gateway = "10.254.0.1".parse().unwrap();
        for destination in ["10.0.0.0/8", "10.254.0.0/30", "10.254.0.2", "10.254.0.3/32"] {
            assert!(check_routes(gateway, &[serde_json::json!({"dst": destination})]).is_err());
        }
        let routes = serde_json::json!([
            {"dst": "default"}, {"dst": "10.254.0.4/30"}, {"dst": "192.168.50.0/24"}
        ]);
        assert!(check_routes(gateway, routes.as_array().unwrap()).is_ok());
    }

    #[test]
    fn journal_name_does_not_authorize_an_unmarked_or_replaced_tap() {
        let lease = test_lease();
        let unmarked = serde_json::json!({"ifname": lease.tap});
        assert!(owned_link(&lease, &[unmarked]).is_err());
        let replaced = serde_json::json!({"ifname": lease.tap, "ifalias": format!("{MARKER}:{}", "b".repeat(32))});
        assert!(owned_link(&lease, &[replaced]).is_err());
        let owned = serde_json::json!({"ifname": lease.tap, "ifalias": format!("{MARKER}:{}", lease.lease)});
        assert!(owned_link(&lease, &[owned]).unwrap().is_some());
        assert!(owned_link(&lease, &[]).unwrap().is_none());
    }
}
