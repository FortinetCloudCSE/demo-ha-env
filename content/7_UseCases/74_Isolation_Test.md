---
title: "Isolation Test"
weight: 4
---

## Prove east cannot reach west

| Test | From | To | Expected |
|---|---|---|---|
| Same site | site A east instance | site A west instance | blocked |
| Cross site, wrong customer | site A east instance | site B west instance | blocked |
| Cross site, wrong customer | site A west instance | site B east instance | blocked |
| Same customer, cross site | site A east instance | site B east instance | works |

## Run

From the site A east instance:

```
ping -c 3 10.1.20.<host>       # west, same site     → no reply
ping -c 3 10.2.20.<host>       # west, other site    → no reply
ping -c 3 10.2.10.<host>       # east, other site    → replies
```

## Read the evidence on the FortiGate

The traffic log shows the attempts as denied by policy 7:

```
execute log filter category 0
execute log filter field policyid 7
execute log display
```

Or in the GUI: **Log & Report > Forward Traffic**, filter on the policy name `deny-east-west`.

## What stops it

The east to west ping is stopped by more than one control:

1. there is **no route** from the east instance to a west address that is not through the firewall's east interface
2. the firewall has **no accept policy** from `gre-east` to `gre-west` or to `gre-west-x`
3. policy 7 **denies and logs** it
4. the TGW prefix-lists keep the west prefix of the other site out of the east spoke's route table

An attempt that gets past one control meets the next.
