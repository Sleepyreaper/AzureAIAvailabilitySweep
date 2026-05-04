# Azure AI Availability Sweep

Find regions where your Azure subscription can actually deploy **Azure AI Search** and **Azure OpenAI** models — not just where Microsoft says the services are offered.

## The Problem

A customer tries to deploy Azure AI Search in `eastus` on a fresh subscription — it fails. The Azure docs say the service is available there. The portal isn't clear about *why* it failed. Was it capacity? Quota? Tenant policy? Subscription type?

Existing CLI options give you registration state or docs-level availability, neither of which reflects whether **your specific subscription** can deploy **right now** in **that region**.

## What This Does

`check-ai-region-capacity.sh` queries the **real per-subscription quota APIs**:

| Service       | API Used                                                                 | What It Tells You                                              |
|---------------|--------------------------------------------------------------------------|----------------------------------------------------------------|
| AI Search     | `Microsoft.Search/locations/{region}/usages?api-version=2023-11-01`     | Per-SKU allowance. `limit: 0` = blocked. `limit > current` = deployable. |
| Azure OpenAI  | `az cognitiveservices model list -l {region}`                            | Which models can be deployed in region (e.g., gpt-5.4 isn't in westus2). |
| OpenAI quota  | `az cognitiveservices usage list -l {region}`                            | Per-model TPM (tokens-per-minute) quota assigned to your sub. |

## Quick Start

```bash
# Default: 11 North America regions, gpt-5.4 model, basic Search SKU
./check-ai-region-capacity.sh

# Specific subscription + Standard Search SKU + gpt-5.1 model
./check-ai-region-capacity.sh --sub <subscription-id> --model gpt-5.1 --search-sku standard

# Region scopes
./check-ai-region-capacity.sh --na     # North America (default)
./check-ai-region-capacity.sh --eu     # Europe
./check-ai-region-capacity.sh --apac   # Asia / Pacific / Middle East
./check-ai-region-capacity.sh --all    # Everything

# Machine-readable output
./check-ai-region-capacity.sh --json | jq '.[] | select(.verdict == "★ DEPLOY HERE")'
```

## Sample Output

```
Subscription: Brad NonProd
  Model under test: gpt-5.4
  Search SKU under test: basic
  Scope: na (11 regions)

Region                 | Search (basic)         | OpenAI gpt-5.4                   | Verdict
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
eastus                 | ✓ 12/12 avail          | ✓ 1000K/1000K TPM (GlobalStandard) | ★ DEPLOY HERE
eastus2                | ✓ 12/12 avail          | ✓ 300K/1000K TPM (GlobalStandard)  | ★ DEPLOY HERE
westus                 | ✓ 12/12 avail          | ✓ 1000K/1000K TPM (GlobalStandard) | ★ DEPLOY HERE
westus2                | ✓ 11/12 avail          | ✗ gpt-5.4 not offered              | Search OK, OpenAI gap
westus3                | ✓ 12/12 avail          | ✓ 1000K/1000K TPM (GlobalStandard) | ★ DEPLOY HERE
centralus              | ✓ 12/12 avail          | ✓ 1000K/1000K TPM (GlobalStandard) | ★ DEPLOY HERE
canadacentral          | ✓ 12/12 avail          | ✓ 1000K/1000K TPM (GlobalStandard) | ★ DEPLOY HERE
mexicocentral          | ✗ region not offered   | ✗ gpt-5.4 not offered              | skip
```

## Reading the Results

| Status                       | Meaning                                                              |
|------------------------------|----------------------------------------------------------------------|
| `✓ 12/12 avail`              | 12 search services allowed in region, 0 used. You can deploy.        |
| `✗ SKU blocked (limit=0)`    | Tenant or capacity policy explicitly blocks that SKU in that region. |
| `✗ region not offered`       | Microsoft.Search isn't deployed to that region at all.               |
| `✓ 1000K/1000K TPM`          | 1M tokens/minute available, none used.                               |
| `✗ {model} not offered`      | Model isn't published to that region (region/version mismatch).      |
| `◐ offered, no quota in sub` | Model exists but subscription has 0 TPM — request increase or pick another region. |
| `★ DEPLOY HERE`              | Both services can be deployed today. Pick this region.               |

## Common One-Liners

These work standalone, no script needed:

```bash
# AI Search quota in one region
az rest --method get \
  --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/providers/Microsoft.Search/locations/centralus/usages?api-version=2023-11-01" \
  | jq '.value[] | {sku: .name.value, limit, used: .currentValue}'

# Which OpenAI models are in this region (with which SKUs)
az cognitiveservices model list -l eastus -o json \
  | jq -r '.[] | select(.model.name | test("gpt-5|o3|embedding"; "i"))
           | "\(.model.name) v\(.model.version) → \([.model.skus[].name] | join(","))"' \
  | sort -u

# OpenAI TPM quota for a specific model
az cognitiveservices usage list -l eastus -o json \
  | jq '.[] | select(.name.value | endswith(".gpt-5.4"))
        | {sku: .name.value, limit_K_TPM: .limit, used: .currentValue}'

# Is a provider registered on this subscription?
az provider show --namespace Microsoft.Search --query registrationState
az provider show --namespace Microsoft.CognitiveServices --query registrationState
```

## When the Script Says "★ DEPLOY HERE" But Deployment Still Fails

| Symptom / Error                       | Cause                                  | Fix                                                                 |
|---------------------------------------|----------------------------------------|---------------------------------------------------------------------|
| `SubscriptionNotRegistered`           | Provider not registered                | `az provider register --namespace Microsoft.Search`                 |
| `OperationNotAllowed`                 | Subscription type restriction (Free)   | Upgrade subscription or use `--sku free`                            |
| `LocationNotAvailableForResourceType` | Tenant policy blocks region            | Azure Portal → Policy assignments                                   |
| `InsufficientQuota`                   | Quota exhausted at MSFT capacity level | Open support ticket OR pick another `★` region                      |
| `ModelNotAvailable`                   | Wrong model version for region         | Run `az cognitiveservices model list -l <region>` to see what's offered |

## Region Sets (as of May 2026)

**North America (`--na`)** — 11 regions
`eastus, eastus2, westus, westus2, westus3, centralus, northcentralus, southcentralus, canadacentral, canadaeast, mexicocentral`

**Europe (`--eu`)** — 17 regions
`westeurope, northeurope, uksouth, ukwest, francecentral, francesouth, germanywestcentral, germanynorth, swedencentral, swedensouth, switzerlandnorth, switzerlandwest, norwayeast, norwaywest, italynorth, polandcentral, spaincentral`

**Asia / Pacific / MEA (`--apac`)** — 18 regions
`japaneast, japanwest, australiaeast, australiasoutheast, australiacentral, southeastasia, eastasia, koreacentral, koreasouth, centralindia, southindia, westindia, uaenorth, uaecentral, qatarcentral, israelcentral, southafricanorth`

## Requirements

- `az` CLI (v2.50+) — logged in via `az login`
- `jq` — JSON processor (`brew install jq` / `apt install jq`)
- Reader access to the target subscription

## License

MIT — see [LICENSE](LICENSE)
