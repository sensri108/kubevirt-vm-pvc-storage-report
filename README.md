# KubeVirt VM → PVC Storage Report

A single-file Bash tool that answers a question KubeVirt and OpenShift Virtualization make surprisingly hard: **for every VM in my cluster, which PVCs back it, how much space did I provision, and how much is actually used?**

`oc get vm` tells you nothing about storage. `oc get pvc` tells you nothing about which VM owns a claim. This script joins the two — walking each `VirtualMachine`'s volume list, resolving every `persistentVolumeClaim` and `dataVolume` reference to a real PVC, and (optionally) enriching each row with live usage from Prometheus/Thanos.

Output is a terminal table, CSV, or JSON.

```
NAMESPACE     VM NAME        VM STATUS  PVC NAME               STORAGE CLASS               PVC PHASE  ACCESS MODE    PROVISIONED  USED        USAGE%
team-alpha    app-web-01     Running    app-web-01-disk-0-a1b   px-rwx-block-kubevirt-demo  Bound      ReadWriteMany  100.00 GiB   34.57 GiB   34.60%
team-alpha    app-web-01     Running    app-web-01-disk-1-d3e   px-rwx-block-kubevirt-demo  Bound      ReadWriteMany  1000.00 GiB  6.60 GiB    0.70%
team-gamma    build-cache-01 Running    build-cache-01-disk-0   px-rwx-block-kubevirt-demo  Bound      ReadWriteMany  50.00 GiB    48.75 GiB   97.50%

Summary
  VMs found         : 14
  PVC rows          : 36
  Total Provisioned : 17514.00 GiB
  Total Used        : 4761.80 GiB
```

---

## Why this exists

Virtual machines on Kubernetes are thin-provisioned by default, and the gap between *provisioned* and *used* is where storage budgets quietly disappear. A 1000 GiB data disk sitting at 0.7% utilization looks identical to a full one from the control plane's perspective — both are just a `Bound` PVC.

Concretely, this report surfaces:

- **Overprovisioning.** Disks provisioned at 10–50× actual usage, reclaimable on the next maintenance window.
- **Imminent full disks.** A VM disk at 97% doesn't page anyone until the guest filesystem wedges. Sorting the CSV by `USAGE%` gives you the list before that happens.
- **Chargeback and capacity planning.** Per-namespace provisioned totals, straight into a spreadsheet.
- **Orphaned and mis-referenced claims.** VMs referencing PVCs that don't exist show up as `NotFound` rather than failing silently.

## How it works

```
   VirtualMachines            PVCs                  Prometheus / Thanos
        │                      │                            │
        │ .spec.template       │ .status.capacity           │ px_volume_usage_bytes
        │  .spec.volumes[]     │  .storage                  │  {namespace, pvc}
        │                      │ .spec.storageClassName     │
        ▼                      ▼                            ▼
   claimName / dataVolume.name ──► join on "namespace/pvc-name" ──► report row
```

1. **Collect VMs** — `oc get virtualmachines` over one namespace or all. For each VM the script reads `.spec.template.spec.volumes[]` and extracts `persistentVolumeClaim.claimName` or, for CDI-managed disks, `dataVolume.name`. Because a DataVolume creates a PVC of the same name, both resolve through one lookup path. Results are `sort -u`'d so a volume referenced twice counts once.
2. **Collect PVCs** — one bulk `oc get pvc` call, indexed into associative arrays keyed `namespace/name`. Capacity is read from `.status.capacity.storage`, falling back to `.spec.resources.requests.storage` for claims not yet bound.
3. **Collect DataVolumes** — fetched for phase information; tolerated as empty if CDI isn't installed.
4. **Collect usage (optional)** — if `-p` is given, one instant query per metric against Prometheus/Thanos, indexed by the same `namespace/pvc` key.
5. **Join and render** — every VM/PVC pair becomes a row. VMs with no disks emit a single `(no-disk)` row so they don't vanish from the inventory.

Everything is bulk-fetched: the script makes a constant number of API calls regardless of cluster size, not one per VM.

## Requirements

| | |
|---|---|
| **bash 4.0+** | Uses associative arrays (`declare -A`) and `mapfile`. **macOS ships bash 3.2 — see below.** |
| **`oc`** | Logged in (`oc login`). `kubectl` works with a small change, see [Using kubectl](#using-kubectl). |
| **`jq`** | All JSON parsing. |
| **`curl`, `awk`, `column`** | Present on essentially every system. |
| **Prometheus/Thanos** | Optional. Without it the report still gives you full provisioned-capacity inventory; `USED` and `USAGE%` read `N/A`. |

> **macOS users:** the bundled bash is 3.2 (from 2007) and will fail with `declare: -A: invalid option`. Install a modern bash with `brew install bash`, then run the script with `/opt/homebrew/bin/bash vm-pvc-storage-report.sh …` — or just run it from a Linux jump host.

## Installation

```bash
git clone https://github.com/<your-username>/kubevirt-vm-pvc-storage-report.git
cd kubevirt-vm-pvc-storage-report
chmod +x vm-pvc-storage-report.sh
```

## Usage

```bash
./vm-pvc-storage-report.sh [OPTIONS]
```

| Option | Description |
|---|---|
| `-n`, `--namespace <ns>` | Report on a single namespace. Defaults to your current `oc project`. |
| `-A`, `--all-namespaces` | Scan the entire cluster. |
| `-o`, `--output <fmt>` | `table` (default), `csv`, or `json`. |
| `-p`, `--prometheus <url>` | Prometheus/Thanos base URL. Enables the `USED` and `USAGE%` columns. |
| `-t`, `--token <tok>` | Bearer token for Prometheus. Defaults to `oc whoami -t`. |

### Examples

```bash
chmod +x vm-pvc-storage-report.sh

# Current project, table output (provisioned only)
./vm-pvc-storage-report.sh

# Specific namespace
./vm-pvc-storage-report.sh -n openshift-cnv

# All namespaces, CSV output
./vm-pvc-storage-report.sh -A -o csv

# With used-space from Prometheus (gets you the USED + USAGE% columns)
PROM=$(oc get route -n openshift-monitoring thanos-querier -o jsonpath='https://{.spec.host}')
./vm-pvc-storage-report.sh -A -p "$PROM" -o table

# JSON output for downstream processing
./vm-pvc-storage-report.sh -A -o json
```

Note that the `jsonpath` above already emits the `https://` scheme, so `$PROM` is passed
through bare. Prefixing it again — `-p "https://${PROM}"` — yields `https://https://host`
and every usage query fails, silently degrading the report to `N/A` in the USED column.

To sanity-check the URL before a long run:

```bash
echo "$PROM"    # -> https://thanos-querier-openshift-monitoring.apps.example.com
```

The last two invocations omit `-p`, so they report **provisioned capacity only**. That
is still the complete VM-to-PVC inventory — you just get `N/A` for `USED` and `USAGE%`.
Add `-p "$PROM"` to any of them for live utilization.

### Output files

`table` prints to the terminal *and* writes a CSV copy. All file output is named `vm-pvc-report-YYYYMMDD-HHMMSS.{csv,json}` in the working directory.

## Output reference

| Column | Source | Notes |
|---|---|---|
| `NAMESPACE` | `.metadata.namespace` | |
| `VM NAME` | `.metadata.name` | |
| `VM STATUS` | `.status.printableStatus` | `Running`, `Stopped`, `Provisioning`… |
| `PVC NAME` | volume `claimName` / `dataVolume.name` | `(no-disk)` if the VM defines no persistent volumes |
| `STORAGE CLASS` | `.spec.storageClassName` | |
| `PVC PHASE` | `.status.phase` | `NotFound` means the VM references a PVC that does not exist |
| `ACCESS MODE` | `.spec.accessModes[0]` | First mode only |
| `PROVISIONED` | `.status.capacity.storage` | Normalized to GiB |
| `USED` | `px_volume_usage_bytes` | `N/A` without `-p`, or if the volume has no series |
| `USAGE%` | computed | `used / provisioned × 100` |

Every size is normalized to **GiB**. The converter handles `Ti`/`Gi`/`Mi`/`Ki` binary units, decimal `G`/`M`, and bare byte counts — so a PVC requested as `1Ti` and one requested as `1024Gi` sum correctly.

### The JSON shape

```json
{
  "generated": "2026-07-21T10:14:02Z",
  "scope": "all namespaces",
  "summary": {
    "vm_count": 14,
    "pvc_rows": 36,
    "total_provisioned_gib": 17514.00,
    "total_used_gib": 4761.80
  },
  "rows": [
    {
      "namespace": "team-alpha",
      "vm_name": "app-web-01",
      "vm_status": "Running",
      "pvc_name": "app-web-01-disk-0-a1b2c",
      "storage_class": "px-rwx-block-kubevirt-demo",
      "pvc_phase": "Bound",
      "access_mode": "ReadWriteMany",
      "provisioned_gib": "100.00 GiB",
      "used_gib": "34.57 GiB",
      "usage_pct": "34.60%"
    }
  ]
}
```

`total_used_gib` is `null` when no usage metrics were collected.

## Where "used" comes from — and why it isn't kubelet

The obvious metric for volume usage is `kubelet_volume_stats_used_bytes`. **It does not work for KubeVirt VM disks**, and this trips people up constantly.

KubeVirt attaches VM disks as **raw block volumes** (`volumeMode: Block`). The kubelet reports filesystem-level statistics, which requires a mounted filesystem it can `statfs()`. A raw block device has no filesystem from the node's perspective — the guest OS formats it internally, invisibly to the kubelet. So `kubelet_volume_stats_*` simply emits no series for these PVCs.

Usage therefore has to come from the storage layer, which sees actual block allocation. This script queries Portworx:

```promql
px_volume_usage_bytes      # bytes actually allocated
px_volume_capacity_bytes   # provisioned capacity, per the storage layer
```

Results are keyed on `namespace` (falling back to `exported_namespace`, which is what you get when Prometheus federation relabels the original) and `pvc`.

### Adapting to other storage

If you don't run Portworx, change the two metric names in the `fetch_metric` calls near the top of the script:

```bash
fetch_metric px_volume_usage_bytes    PROM_USED
fetch_metric px_volume_capacity_bytes PROM_CAP
```

Equivalents by backend:

| Storage | Usage metric |
|---|---|
| Portworx | `px_volume_usage_bytes` *(default)* |
| Ceph / ODF | `ceph_rbd_image_actual_provisioned_bytes` |
| NetApp Trident | `trident_volume_used_bytes` |
| Filesystem-mode PVCs | `kubelet_volume_stats_used_bytes` *(works only for `volumeMode: Filesystem`)* |

The only requirement is that the series carry `namespace` and `pvc` labels. If yours are labelled differently, adjust the `jq` selector inside `fetch_metric`.

If the query fails or returns nothing, the script warns once and continues with `N/A` — a missing Prometheus never costs you the inventory report.

## Using kubectl

The script uses `oc` for login detection and current-project resolution. To run it against upstream KubeVirt with `kubectl`, replace `oc get` with `kubectl get`, drop the `oc whoami` preflight check, and pass `-n` explicitly (there is no `kubectl project -q` equivalent).

## Permissions

The invoking user needs read access to VMs, PVCs, and DataVolumes:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vm-storage-reporter
rules:
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines"]
    verbs: ["get", "list"]
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list"]
```

Reading Prometheus additionally requires `cluster-monitoring-view`.

## Sample output

[`examples/sample-report.csv`](examples/sample-report.csv) is a synthetic report demonstrating the full output shape, including the edge cases worth knowing about:

- multi-disk VMs (a boot disk plus several data disks)
- a `Stopped` VM — stopped VMs still consume provisioned storage, which is exactly the point
- a `dv-`-prefixed PVC created by a CDI DataVolume
- a `(no-disk)` VM
- a `Pending` PVC and a `NotFound` PVC reference
- disks at 97% and 99% utilization sitting next to disks at 0.1%
- the trailing `TOTAL` row

> The data is generated, not from any real cluster. If you commit reports from your own environment, note that they contain namespace names, VM hostnames, storage class identifiers, and a capacity map of your estate — treat them as internal.

## Known limitations

- **`PROM_CAP` is collected but unused.** `px_volume_capacity_bytes` is fetched and indexed, but the report uses the PVC's own `.status.capacity.storage` for the provisioned column. The data is there if you want to add a column reconciling the two — a mismatch between what Kubernetes and the storage layer each believe is provisioned is a genuinely useful signal.
- **Decimal `M` is treated as binary `Mi`.** In the unit converter, decimal `G` is correctly scaled by 0.931322 but decimal `M` is divided by 1024 — so a PVC requested as `1000M` reports 0.98 GiB instead of 0.91 GiB, a ~7% overstatement. Kubernetes storage requests are almost always written in binary units (`Gi`/`Ti`), so this rarely fires; the one-line fix is to change the `M` branch to `r*0.000931322`.
- **Only the first access mode** is shown per PVC.
- **Hotplugged disks** attached at runtime but absent from `.spec.template.spec.volumes` are not reported.
- **Usage is an instant query** — a point-in-time sample, not a max or average over a window. For trend analysis, query the same metric with `query_range`.
- **No pagination.** Very large clusters (thousands of VMs) build the full JSON in memory.

## License

MIT — see [LICENSE](LICENSE).
