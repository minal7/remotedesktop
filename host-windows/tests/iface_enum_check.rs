//! Regression guard for the vendored webrtc-util IPv6 byte-order fix.
//!
//! Upstream webrtc-util 0.17.1 read each Windows IPv6 interface address as
//! native-endian `[u16; 8]`, byte-swapping every 16-bit group on
//! little-endian Windows — `fe80::b774:…` came back as `80fe::74b7:…`. The
//! mangled address can't be bound, so ICE gathered no usable IPv6
//! candidates and every Windows session was forced onto IPv4. The vendored
//! copy under `third_party/webrtc-util` reads the raw wire-order bytes.
//!
//! Run: `cargo test --release --test iface_enum_check -- --nocapture`

use std::net::IpAddr;

#[test]
fn ipv6_interface_addresses_are_not_byte_swapped() {
    let ifaces = webrtc_util::ifaces::ifaces().expect("enumerate interfaces");
    println!("\n===== webrtc-util ifaces() ({}) =====", ifaces.len());

    let mut saw_ipv6 = false;
    for i in &ifaces {
        let Some(addr) = i.addr else { continue };
        println!("  kind={:?} addr={}", i.kind, addr.ip());
        let IpAddr::V6(v6) = addr.ip() else { continue };
        saw_ipv6 = true;

        // The byte-swap turns a link-local `fe80::/10` address into one
        // whose first group is `0x80fe` — i.e. it lands in `80fe::/16`.
        // A correctly parsed address never starts with that group.
        let first = v6.segments()[0];
        assert_ne!(
            first, 0x80fe,
            "byte-swapped IPv6 address leaked from webrtc-util: {v6} \
             (real address was almost certainly fe80::…). The vendored \
             webrtc-util fix is not in effect."
        );

        // Any link-local we surface must be a genuine fe80::/10 address.
        // (We don't require one to exist — CI runners may have none — but
        // if we see link-local-shaped bits they must be the real fe80.)
        if (first & 0xffc0) == 0x0080 {
            panic!(
                "IPv6 address {v6} starts in 0080::/10 — that is the \
                    byte-swapped image of fe80::/10, the exact corruption \
                    this test guards against."
            );
        }
    }

    if !saw_ipv6 {
        println!("(no IPv6 interface addresses on this host — nothing to assert)");
    }
}
