#!/usr/bin/env bash
# =============================================================================
# vm-pvc-storage-report.sh
# KubeVirt / OpenShift Virtualization — VM -> PVC Storage Report
#
# For each VM, lists all attached PVCs with:
#   - Provisioned size  (from PVC .status.capacity.storage)
#   - Used space        (from Prometheus/Thanos px_volume_usage_bytes)
#   - Usage %
#   - StorageClass, PVC phase, access mode
#
# NOTE: used-space comes from the Portworx metric px_volume_usage_bytes, not
# kubelet_volume_stats_used_bytes. KubeVirt disks are raw block volumes, which
# the kubelet does not report filesystem stats for. On non-Portworx storage the
# USED and USAGE% columns will be N/A -- see README "Adapting to other storage".
#
# Prerequisites: bash 4.0+, oc (logged in), jq
# Optional:      Prometheus/Thanos URL for used-space metrics
#
# Usage:
#   ./vm-pvc-storage-report.sh [OPTIONS]
#
# Options:
#   -n | --namespace  <ns>   Single namespace (default: current oc project)
#   -A | --all-namespaces    Scan every namespace
#   -o | --output     <fmt>  table (default) | csv | json
#   -p | --prometheus <url>  Prometheus base URL
#   -t | --token      <tok>  Bearer token (default: oc whoami -t)
#
# Maintainer: Sen Sri (https://github.com/sensri108)
# Repository: https://github.com/sensri108/kubevirt-vm-pvc-storage-report
# License:    MIT
# =============================================================================

set -euo pipefail

NAMESPACE=""; ALL_NS=false; FMT="table"; PROM_URL=""; TOKEN=""
REPORT="vm-pvc-report-$(date +%Y%m%d-%H%M%S)"

CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)      NAMESPACE="$2"; shift 2 ;;
    -A|--all-namespaces) ALL_NS=true;    shift   ;;
    -o|--output)         FMT="$2";       shift 2 ;;
    -p|--prometheus)     PROM_URL="$2";  shift 2 ;;
    -t|--token)          TOKEN="$2";     shift 2 ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

command -v oc  &>/dev/null || { err "'oc' not in PATH"; exit 1; }
command -v jq  &>/dev/null || { err "'jq' not in PATH"; exit 1; }
oc whoami &>/dev/null      || { err "Not logged in (run 'oc login')"; exit 1; }

if $ALL_NS; then
  NS_FLAG="--all-namespaces"; NS_LABEL="all namespaces"
elif [[ -n "$NAMESPACE" ]]; then
  NS_FLAG="-n $NAMESPACE";    NS_LABEL="namespace: $NAMESPACE"
else
  NAMESPACE=$(oc project -q 2>/dev/null || echo "default")
  NS_FLAG="-n $NAMESPACE";    NS_LABEL="namespace: $NAMESPACE"
fi

# ── unit converter ─────────────────────────────────────────────────────────
# Normalizes any Kubernetes quantity suffix to GiB. Covers the full binary set
# (Ki/Mi/Gi/Ti/Pi/Ei) and the decimal set (k/M/G/T/P/E); a bare number is
# treated as bytes. Suffixes are anchored, so "Ti" is never matched by the "T"
# branch. Every suffix must have a branch: an unhandled one falls through to
# the byte branch, where awk coerces e.g. "1Pi" to 1 and reports 0.00 GiB --
# silently under-counting a real volume rather than erroring.
to_gib() {
  awk -v r="$1" 'BEGIN {
    # binary (power-of-two) suffixes
    if      (r~/Ei$/) { sub(/Ei$/,"",r); printf "%.2f",r*1073741824 }
    else if (r~/Pi$/) { sub(/Pi$/,"",r); printf "%.2f",r*1048576 }
    else if (r~/Ti$/) { sub(/Ti$/,"",r); printf "%.2f",r*1024 }
    else if (r~/Gi$/) { sub(/Gi$/,"",r); printf "%.2f",r }
    else if (r~/Mi$/) { sub(/Mi$/,"",r); printf "%.2f",r/1024 }
    else if (r~/Ki$/) { sub(/Ki$/,"",r); printf "%.2f",r/1048576 }
    # decimal (power-of-ten) suffixes, scaled by 10^n / 2^30
    else if (r~/E$/)  { sub(/E$/, "",r); printf "%.2f",r*931322574.615478 }
    else if (r~/P$/)  { sub(/P$/, "",r); printf "%.2f",r*931322.574615478 }
    else if (r~/T$/)  { sub(/T$/, "",r); printf "%.2f",r*931.322574615478 }
    else if (r~/G$/)  { sub(/G$/, "",r); printf "%.2f",r*0.931322574615478 }
    else if (r~/M$/)  { sub(/M$/, "",r); printf "%.2f",r*0.000931322574615478 }
    else if (r~/k$/)  { sub(/k$/, "",r); printf "%.2f",r*0.000000931322574615478 }
    # bare byte count
    else              { printf "%.2f",r/1073741824 }
  }'
}

# ── human-readable scaling for summary totals ──────────────────────────────
# Takes a GiB value and scales it to the largest unit that keeps it readable.
# Used for the summary line only -- per-row values stay in GiB so that rows
# remain sortable and directly comparable in a spreadsheet.
fmt_size() {
  awk -v g="$1" 'BEGIN {
    if      (g >= 1048576) printf "%.2f PiB", g/1048576
    else if (g >= 1024)    printf "%.2f TiB", g/1024
    else                   printf "%.2f GiB", g
  }'
}

# ── optional Prometheus used-bytes ─────────────────────────────────────────
# ── Portworx used + capacity from Thanos (block-volume aware) ────────────────
declare -A PROM_USED PROM_CAP
if [[ -n "$PROM_URL" ]]; then
  log "Querying Thanos for px_volume_usage_bytes / px_volume_capacity_bytes ..."
  [[ -z "$TOKEN" ]] && TOKEN=$(oc whoami -t 2>/dev/null || true)

  fetch_metric() {  # $1 = metric name, $2 = target assoc-array name
    local metric="$1" arrname="$2"
    local enc resp status cnt=0
    enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$metric" 2>/dev/null || echo "$metric")
    resp=$(curl -sk --max-time 30 -H "Authorization: Bearer $TOKEN" \
      "${PROM_URL}/api/v1/query?query=${enc}" 2>/dev/null || true)
    status=$(echo "$resp" | jq -r '.status // "error"' 2>/dev/null)
    if [[ "$status" != "success" ]]; then
      warn "$metric query status='$status' — that column will be N/A"
      return
    fi
    while IFS=$'\t' read -r ns pvc val; do
      [[ -z "$ns" || -z "$pvc" ]] && continue
      printf -v "${arrname}[${ns}/${pvc}]" '%s' "$val"
      (( cnt++ )) || true
    done < <(echo "$resp" | jq -r '.data.result[]? |
      [ (.metric.exported_namespace // .metric.namespace // ""),
        (.metric.pvc // ""),
        .value[1] ] | @tsv')
    log "$metric: loaded $cnt series"
  }

  fetch_metric px_volume_usage_bytes    PROM_USED
  fetch_metric px_volume_capacity_bytes PROM_CAP
fi
# ── fetch resources ─────────────────────────────────────────────────────────
log "Fetching VirtualMachines ($NS_LABEL) ..."
VM_JSON=$(oc get virtualmachines $NS_FLAG -o json) || \
  { err "Cannot list VMs — is OpenShift Virtualization installed?"; exit 1; }
VM_COUNT=$(echo "$VM_JSON" | jq '.items|length')
log "Found ${VM_COUNT} VM(s)"

log "Fetching PVCs ..."
PVC_JSON=$(oc get pvc $NS_FLAG -o json 2>/dev/null)
declare -A PVC_CAP PVC_SC PVC_PHASE PVC_AM
while IFS= read -r p; do
  ns=$(echo "$p" | jq -r '.metadata.namespace')
  nm=$(echo "$p" | jq -r '.metadata.name')
  ca=$(echo "$p" | jq -r '.status.capacity.storage // .spec.resources.requests.storage // "0"')
  sc=$(echo "$p" | jq -r '.spec.storageClassName // "-"')
  ph=$(echo "$p" | jq -r '.status.phase // "Unknown"')
  am=$(echo "$p" | jq -r '.spec.accessModes[0] // "-"')
  k="${ns}/${nm}"
  PVC_CAP["$k"]="$ca"; PVC_SC["$k"]="$sc"; PVC_PHASE["$k"]="$ph"; PVC_AM["$k"]="$am"
done < <(echo "$PVC_JSON" | jq -c '.items[]' 2>/dev/null)

log "Fetching DataVolumes ..."
DV_JSON=$(oc get datavolumes $NS_FLAG -o json 2>/dev/null || echo '{"items":[]}')
declare -A DV_PHASE
while IFS= read -r d; do
  ns=$(echo "$d" | jq -r '.metadata.namespace')
  nm=$(echo "$d" | jq -r '.metadata.name')
  ph=$(echo "$d" | jq -r '.status.phase // "Unknown"')
  DV_PHASE["${ns}/${nm}"]="$ph"
done < <(echo "$DV_JSON" | jq -c '.items[]' 2>/dev/null)

# ── build rows ──────────────────────────────────────────────────────────────
declare -a ROWS
TOTAL_PROV=0; TOTAL_USED=0; ROWS_WITH_USED=0
HDR="NAMESPACE\tVM NAME\tVM STATUS\tPVC NAME\tSTORAGE CLASS\tPVC PHASE\tACCESS MODE\tPROVISIONED\tUSED\tUSAGE%"

while IFS= read -r vm; do
  vm_nm=$(echo "$vm" | jq -r '.metadata.name')
  vm_ns=$(echo "$vm" | jq -r '.metadata.namespace')
  vm_st=$(echo "$vm" | jq -r '.status.printableStatus // "Unknown"')

  mapfile -t pvcs < <(echo "$vm" | jq -r '
    .spec.template.spec.volumes[]? |
    (.persistentVolumeClaim.claimName // .dataVolume.name // empty)
  ' 2>/dev/null | sort -u)

  if [[ ${#pvcs[@]} -eq 0 ]]; then
    ROWS+=("${vm_ns}\t${vm_nm}\t${vm_st}\t(no-disk)\t-\t-\t-\t-\tN/A\tN/A")
    continue
  fi

  for pvc in "${pvcs[@]}"; do
    k="${vm_ns}/${pvc}"
    cap="${PVC_CAP[$k]:-0}"; sc="${PVC_SC[$k]:--}"
    pp="${PVC_PHASE[$k]:-NotFound}"; am="${PVC_AM[$k]:--}"

    prov=$(to_gib "$cap")
    TOTAL_PROV=$(awk "BEGIN{printf \"%.2f\",$TOTAL_PROV+$prov}")

    used="N/A"; upct="N/A"
    if [[ -n "${PROM_USED[$k]+_}" ]]; then
      by="${PROM_USED[$k]}"
      used=$(awk "BEGIN{printf \"%.2f\", $by/1073741824}")
      TOTAL_USED=$(awk "BEGIN{printf \"%.2f\", $TOTAL_USED+$used}")
      (( ROWS_WITH_USED++ )) || true
      if awk "BEGIN{exit ($prov==0)}"; then
        upct=$(awk "BEGIN{printf \"%.1f%%\", ($used/$prov)*100}")
      fi
    fi

    ROWS+=("${vm_ns}\t${vm_nm}\t${vm_st}\t${pvc}\t${sc}\t${pp}\t${am}\t${prov} GiB\t${used} GiB\t${upct}")
  done
done < <(echo "$VM_JSON" | jq -c '.items[]' 2>/dev/null)

# ── renderers ───────────────────────────────────────────────────────────────
render_table() {
  echo -e "${BOLD}${CYAN}"
  printf '=%.0s' {1..110}; echo
  printf "  KubeVirt VM -> PVC Storage Report\n"
  printf "  Generated : %s\n" "$(date)"
  printf "  Scope     : %s\n" "$NS_LABEL"
  printf '=%.0s' {1..110}; echo
  echo -e "${NC}"
  ( echo -e "$HDR"; for r in "${ROWS[@]}"; do echo -e "$r"; done ) | column -t -s $'\t'
  echo ""
  echo -e "${BOLD}Summary${NC}"
  printf "  VMs found         : %s\n"     "$VM_COUNT"
  printf "  PVC rows          : %s\n"     "${#ROWS[@]}"
  printf "  Total Provisioned : %s  (%s GiB)\n" "$(fmt_size "$TOTAL_PROV")" "$TOTAL_PROV"
  if (( ROWS_WITH_USED > 0 )); then
    printf "  Total Used        : %s  (%s GiB)\n" "$(fmt_size "$TOTAL_USED")" "$TOTAL_USED"
  else
    printf "  Total Used        : N/A  (pass -p <prometheus-url> to enable)\n"
  fi
}

render_csv() {
  local f="${REPORT}.csv"
  ( echo -e "$HDR"; for r in "${ROWS[@]}"; do echo -e "$r"; done ) | tr '\t' ',' > "$f"
  echo "TOTAL,,,,,,,$TOTAL_PROV GiB,$TOTAL_USED GiB," >> "$f"
  log "CSV saved -> $f"
}

render_json() {
  local f="${REPORT}.json"
  local keys=("namespace" "vm_name" "vm_status" "pvc_name" "storage_class"
              "pvc_phase" "access_mode" "provisioned_gib" "used_gib" "usage_pct")
  local arr="[" first=true
  for r in "${ROWS[@]}"; do
    IFS=$'\t' read -ra flds <<< "$(echo -e "$r")"
    $first && first=false || arr+=","
    arr+="{"
    for i in "${!keys[@]}"; do arr+="\"${keys[$i]}\":\"${flds[$i]:-}\","; done
    arr="${arr%,}}"
  done
  arr+="]"
  echo "$arr" | jq --arg scope "$NS_LABEL" \
    --arg prov_h "$(fmt_size "$TOTAL_PROV")" \
    --arg used_h "$(fmt_size "$TOTAL_USED")" '{
    generated: (now|todate), scope: $scope,
    summary: { vm_count: '"$VM_COUNT"', pvc_rows: '"${#ROWS[@]}"',
      total_provisioned_gib: '"$TOTAL_PROV"',
      total_provisioned_human: $prov_h,
      total_used_gib: (if '"$ROWS_WITH_USED"'>0 then '"$TOTAL_USED"' else null end),
      total_used_human: (if '"$ROWS_WITH_USED"'>0 then $used_h else null end) },
    rows: . }' > "$f"
  log "JSON saved -> $f"
}

# ── run ─────────────────────────────────────────────────────────────────────
case "$FMT" in
  table) render_table; render_csv; log "CSV copy: ${REPORT}.csv" ;;
  csv)   render_csv ;;
  json)  render_json ;;
  *) err "Unknown format '$FMT' (table|csv|json)"; exit 1 ;;
esac
log "Done."
