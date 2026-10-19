---
title: "Use Cases"
chapter: true
menuTitle: "Use Cases"
weight: 70
---

# Use Cases

Four scenarios that exercise the design, each with the configuration, the test, and what to look at if it fails.

| Use case | What it shows |
|---|---|
| [SSH VIPs](71_ssh_vips/) | Admin access to a spoke instance through the cluster EIP |
| [Internet egress](72_internet_egress/) | A spoke reaching the internet through the primary FortiGate |
| [Cross-site traffic](73_cross_site/) | East to east and west to west across the IPsec tunnel, each in its own GRE tunnel |
| [Isolation test](74_isolation_test/) | Proving east cannot reach west |
