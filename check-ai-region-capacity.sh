#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# Azure AI Availability Sweep
# Find regions with REAL capacity for Azure AI Search + OpenAI models
#
# Uses the actual Azure quota APIs — not registration state, not docs:
#   - AI Search:   GET /providers/Microsoft.Search/locations/{r}/usages
#                  → returns per-SKU allowance (limit:0 = blocked)
#   - OpenAI:      az cognitiveservices model list -l {r}
#                  → returns models that can be deployed in region
#                  az cognitiveservices usage list -l {r}
#                  → returns per-model TPM quota
#
# Usage:
#   ./check-ai-region-capacity.sh                       # NA + curr sub
#   ./check-ai-region-capacity.sh --sub <id>            # subscription override
#   ./check-ai-region-capacity.sh --model gpt-5.4       # specific model
#   ./check-ai-region-capacity.sh --search-sku standard # specific Search SKU
#   ./check-ai-region-capacity.sh --na                  # North America (default)
#   ./check-ai-region-capacity.sh --eu                  # Europe
#   ./check-ai-region-capacity.sh --apac                # Asia/Pacific
#   ./check-ai-region-capacity.sh --all                 # global sweep
#   ./check-ai-region-capacity.sh --json                # machine-readable
# ─────────────────────────────────────────────────────────────────────

set -uo pipefail

SUB=""
MODEL="gpt-5.4"
SEARCH_SKU="basic"
SCOPE="na"
JSON_OUT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --sub)         SUB="$2"; shift 2 ;;
        --model)       MODEL="$2"; shift 2 ;;
        --search-sku)  SEARCH_SKU="$2"; shift 2 ;;
        --na)          SCOPE="na"; shift ;;
        --eu)          SCOPE="eu"; shift ;;
        --apac)        SCOPE="apac"; shift ;;
        --all)         SCOPE="all"; shift ;;
        --json)        JSON_OUT=true; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# Check dependencies
for cmd in az jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is required but not installed."
        [ "$cmd" = "jq" ] && echo "  Install: brew install jq  (macOS)  /  apt install jq  (Linux)"
        [ "$cmd" = "az" ] && echo "  Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
        exit 1
    fi
done

[ -n "$SUB" ] && az account set --subscription "$SUB" >/dev/null
SUB_ID=$(az account show --query id -o tsv 2>/dev/null)
SUB_NAME=$(az account show --query name -o tsv 2>/dev/null)

if [ -z "$SUB_ID" ]; then
    echo "Error: Not logged in. Run: az login"
    exit 1
fi

# Region sets
NA_REGIONS=(eastus eastus2 westus westus2 westus3 centralus northcentralus southcentralus
            canadacentral canadaeast mexicocentral)

EU_REGIONS=(westeurope northeurope uksouth ukwest francecentral francesouth
            germanywestcentral germanynorth swedencentral swedensouth
            switzerlandnorth switzerlandwest norwayeast norwaywest
            italynorth polandcentral spaincentral)

APAC_REGIONS=(japaneast japanwest australiaeast australiasoutheast australiacentral
              southeastasia eastasia koreacentral koreasouth
              centralindia southindia westindia
              uaenorth uaecentral qatarcentral israelcentral southafricanorth)

case "$SCOPE" in
    na)   REGIONS=("${NA_REGIONS[@]}") ;;
    eu)   REGIONS=("${EU_REGIONS[@]}") ;;
    apac) REGIONS=("${APAC_REGIONS[@]}") ;;
    all)  REGIONS=("${NA_REGIONS[@]}" "${EU_REGIONS[@]}" "${APAC_REGIONS[@]}") ;;
esac

if [ "$JSON_OUT" = false ]; then
    echo "Subscription: $SUB_NAME"
    echo "  ID: $SUB_ID"
    echo "  Model under test: $MODEL"
    echo "  Search SKU under test: $SEARCH_SKU"
    echo "  Scope: $SCOPE (${#REGIONS[@]} regions)"
    echo ""
    printf "%-22s | %-22s | %-32s | %s\n" \
        "Region" "Search ($SEARCH_SKU)" "OpenAI $MODEL" "Verdict"
    printf '%.0s─' {1..120}; echo
fi

results_json="[]"

for region in "${REGIONS[@]}"; do
    # ─── AI SEARCH quota ─────────────────────────────────────────────
    search_data=$(az rest --method get \
        --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Search/locations/$region/usages?api-version=2023-11-01" \
        2>/dev/null || echo '{"value":[]}')

    search_limit=$(echo "$search_data" | jq -r --arg sku "$SEARCH_SKU" \
        '.value[] | select(.name.value == $sku) | .limit' 2>/dev/null)
    search_used=$(echo "$search_data" | jq -r --arg sku "$SEARCH_SKU" \
        '.value[] | select(.name.value == $sku) | .currentValue' 2>/dev/null)

    if [ -z "$search_limit" ] || [ "$search_limit" = "null" ]; then
        search_status="✗ region not offered"
        search_ok=false
        search_limit=0
        search_used=0
    elif [ "$search_limit" = "0" ]; then
        search_status="✗ SKU blocked (limit=0)"
        search_ok=false
    else
        search_remaining=$((search_limit - search_used))
        search_status="✓ ${search_remaining}/${search_limit} avail"
        search_ok=true
    fi

    # ─── OPENAI MODEL availability + TPM quota ──────────────────────
    model_data=$(az cognitiveservices model list -l "$region" -o json 2>/dev/null \
        | jq -c --arg m "$MODEL" '[.[] | select(.model.name == $m)] | sort_by(.model.version) | last' \
        2>/dev/null)

    skus="-"
    tpm_limit=0
    tpm_used=0

    if [ -z "$model_data" ] || [ "$model_data" = "null" ]; then
        openai_status="✗ $MODEL not offered"
        openai_ok=false
    else
        skus=$(echo "$model_data" | jq -r '[.model.skus[].name] | join(",")')

        usage_data=$(az cognitiveservices usage list -l "$region" -o json 2>/dev/null || echo '[]')

        # Quota names: OpenAI.{Sku}.{model}
        quota=$(echo "$usage_data" | jq -c --arg m "$MODEL" \
            '[.[] | select(.name.value | endswith("." + $m))] | sort_by(-.limit) | .[0]')

        if [ -z "$quota" ] || [ "$quota" = "null" ]; then
            openai_status="◐ offered, no quota in sub"
            openai_ok=false
        else
            tpm_limit=$(echo "$quota" | jq -r '.limit')
            tpm_used=$(echo "$quota" | jq -r '.currentValue')
            quota_sku=$(echo "$quota" | jq -r '.name.value' | sed -E 's/OpenAI\.([^.]+)\..*/\1/')
            tpm_remaining=$(awk "BEGIN { printf \"%.0f\", $tpm_limit - $tpm_used }")
            openai_status="✓ ${tpm_remaining}K/${tpm_limit%.*}K TPM ($quota_sku)"
            openai_ok=true
        fi
    fi

    # ─── VERDICT ────────────────────────────────────────────────────
    if [ "$search_ok" = true ] && [ "$openai_ok" = true ]; then
        verdict="★ DEPLOY HERE"
    elif [ "$search_ok" = true ]; then
        verdict="Search OK, OpenAI gap"
    elif [ "$openai_ok" = true ]; then
        verdict="OpenAI OK, Search gap"
    else
        verdict="skip"
    fi

    if [ "$JSON_OUT" = true ]; then
        results_json=$(echo "$results_json" | jq \
            --arg r "$region" --arg ss "$search_status" --arg os "$openai_status" \
            --arg v "$verdict" --arg sk "$skus" \
            --argjson sl "${search_limit:-0}" --argjson su "${search_used:-0}" \
            --argjson tl "${tpm_limit:-0}" --argjson tu "${tpm_used:-0}" \
            '. + [{region:$r, search:{status:$ss, limit:$sl, used:$su},
                   openai:{status:$os, model_skus:$sk, tpm_limit:$tl, tpm_used:$tu},
                   verdict:$v}]')
    else
        printf "%-22s | %-22s | %-32s | %s\n" \
            "$region" "$search_status" "$openai_status" "$verdict"
    fi
done

if [ "$JSON_OUT" = true ]; then
    echo "$results_json" | jq .
    exit 0
fi

echo ""
echo "Legend:"
echo "  Search 'limit=0'    → tenant policy or capacity blocks that SKU in that region"
echo "  Search 'not offered'→ Microsoft.Search not deployed to that region"
echo "  OpenAI 'no quota'   → model exists but subscription has 0 TPM allocated"
echo "  TPM unit            → 1K TPM = 1,000 tokens/minute"
echo ""
echo "If a deployment fails despite ★ verdict:"
echo "  • Provider not registered:  az provider register --namespace Microsoft.Search"
echo "                              az provider register --namespace Microsoft.CognitiveServices"
echo "  • Subscription type:        Free/MSDN can't deploy paid SKUs"
echo "  • Tenant policy:            Azure Policy blocking region or SKU"
echo "  • Need quota increase:      portal.azure.com → Quotas → request increase"
