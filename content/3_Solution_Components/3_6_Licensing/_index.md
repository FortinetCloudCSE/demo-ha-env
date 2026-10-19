---
title: "Licensing"
chapter: false
menuTitle: "Licensing"
weight: 36
---

## Use PAYG

`license_type = "payg"` is the setting that works. The AMI is looked up by version against the AMI name
(`FortiGate-VM64-AWSONDEMAND build*(<fortios_version>*)*` for PAYG, `FortiGate-VM64-AWS build*(...)*` for BYOL and FortiFlex).

| Mode | Result on FortiOS 8.0.1 (build 0245) |
|---|---|
| PAYG | License Status: Valid straight away |
| BYOL | License Status: Pending; the update daemon logged `SETUP failed` |
| FortiFlex | Same as BYOL |

## What the failure looked like

On all four BYOL units the license stayed `Pending` and the GUI showed "license is being validated by FortiGuard":

```
get system status | grep -i License
License Status: Pending
License Status: Low-Encryption(LENC)

diagnose test update info
do_setup[341]-Starting SETUP
do_setup[345]-SETUP failed
```

The update debug showed a very short server reply (`data_len=24 ... no res header`) rather than a timeout, so the
connection was reaching a server. FortiCare showed the serial as valid, registered and unexpired. FortiFlex tokens failed the
same way. `LENC` is a property of the FortiCare license, not a failure symptom.

{{% notice info %}}
The cause was not established. It may be on the Fortinet side or specific to that build. A Fortinet support case would need
the serial numbers and the update debug output. PAYG avoids the licensing step and was used instead.
{{% /notice %}}

## While the license is Pending

The **GUI will not load** during that state. TCP to port 443 connects, but the unit sends no TLS reply. This looked like a
networking fault on the management port and was not: with PAYG, the same GUI answered with HTTP 200 on all four units.

## Other options

BYOL and FortiFlex code paths remain in the Terraform (S3 bootstrap of `.lic` files, `scripts/apply_fortiflex.py` at the repository root). They are not
known to work with this build.
