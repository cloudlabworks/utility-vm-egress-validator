# utility-vm-egress-validator

**Pattern:** deploy a small, single-purpose "utility VM" into a cloud landing zone,
run live network-egress tests from inside it, report pass/fail, then delete every
resource it touched — automatically, even on failure.

This is the same technique used to validate a landing zone *before* a real
[Nutanix Cloud Clusters (NC2)](https://www.nutanix.com/products/nutanix-cloud-clusters)
deployment lands in it: confirm the subnet can actually reach the endpoints
Nutanix requires (management, licensing, telemetry) before spending an hour
bringing up bare-metal hosts that will fail at the first health check if egress
is wrong.

## Why a utility VM instead of a checklist

- **Tests reality, not documentation.** A checklist says "port 443 should be
  open." A utility VM either reaches the endpoint over 443 or it doesn't.
- **Zero residue.** Every script here traps `EXIT` — VM/instance, NIC,
  security group or firewall rule, and any temp disk are deleted whether the
  run succeeds, fails, or is interrupted with Ctrl-C.
- **Repeatable.** Same script, same test, every landing zone, every cloud.
- **Cheap.** Minutes of the smallest instance size against hours of debugging
  a stalled cluster deployment.

## Layout

```
azure/validate-landing-zone.sh   # Azure: az vm run-command, NSG-scoped egress test
aws/validate-landing-zone.sh     # AWS: EC2 + SSM Run Command, no SSH key required
gcp/validate-landing-zone.sh     # GCP: Compute Engine startup-script + serial console
```

Each script:

1. Takes the target subnet/VNet/VPC and a list of test endpoints as input.
2. Creates the smallest viable instance in that subnet with no public IP.
3. Runs an HTTPS reachability test against each endpoint from inside the
   instance (not from your workstation — the point is testing the subnet's
   actual egress path).
4. Prints pass/fail per endpoint.
5. Deletes everything it created, via a shell `trap ... EXIT`, regardless of
   how the script exits.

## Endpoint list: bring your own

The exact FQDNs and ports Nutanix requires per cloud are documented in the
**customer-authenticated** Nutanix Support Portal (per-product Ports and
Protocols reference, and the NC2-on-AWS / NC2-on-Google-Cloud deployment
guides). Those pages sit behind a support login, so this repo does not embed
them — that would mean either guessing or reproducing gated documentation.

What's public and used here as the baseline: the [Nutanix Ports and Protocols
Reference Chart](https://next.nutanix.com/installation-configuration-23/ports-and-protocols-reference-chart-40249)
on the Nutanix community site, which documents the general pattern (443/HTTPS
outbound to Nutanix-operated service endpoints for licensing, upgrade, and
support). Each script takes `--endpoint host:port` as a repeatable flag —
populate it from your own account's requirements page before running against
a real landing zone.

## Not a replacement for the official pre-flight checks

This validates network path. It does not replace Nutanix's own NC2 deployment
guide or the portal's built-in pre-checks — run this *in addition to*, as a
fast fail-early signal before you open a support case over what turns out to
be a firewall rule.

## License

MIT — see LICENSE.
