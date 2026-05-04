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

## Real-World Sweep — Microsoft FDPO Tenant (May 4, 2026)

Run against a real internal MSFT FDPO subscription (Brad NonProd, tenant ``) across all 11 North America regions. This is the kind of output you can expect.

### Azure AI Search — SKU availability matrix

`✓ N/M` = N currently used / M allowed.  `✗` = SKU blocked (`limit: 0`).  `—` = region not offered.

| Region          | Free | Basic | Standard | Std2 | Std3 | StorageOpt | EnhDensity1 | Serverless |
|-----------------|------|-------|----------|------|------|------------|-------------|------------|
| eastus          | 0/1  | 0/12  | 0/12     | ✗    | ✗    | ✗          | 0/12        | 0/16       |
| eastus2         | 0/1  | 0/12  | 0/12     | ✗    | ✗    | ✗          | 0/12        | 0/16       |
| westus          | 0/1  | 0/12  | 0/12     | ✗    | ✗    | ✗          | 0/12        | 0/16       |
| westus2         | 0/1  | 1/12  | 0/12     | ✗    | ✗    | ✗          | 0/12        | 0/16       |
| westus3         | 0/1  | 0/12  | 0/12     | ✗    | ✗    | ✗          | 0/12        | 0/16       |
| centralus       | 0/1  | 0/12  | 0/12     | ✗    | ✗    | ✗          | 0/12        | 0/16       |
| northcentralus  | 0/1  | 0/12  | 0/12     | ✗    | ✗    | ✗          | 0/12        | 0/16       |
| southcentralus  | 0/1  | 0/12  | 0/12     | ✗    | ✗    | ✗          | 0/12        | 0/16       |
| canadacentral   | 0/1  | 0/12  | 0/12     | ✗    | ✗    | ✗          | 0/12        | 0/16       |
| canadaeast      | 0/1  | 0/12  | 0/12     | ✗    | ✗    | ✗          | 0/12        | 0/16       |
| mexicocentral   | 0/1  | 0/12  | 0/12     | ✗    | ✗    | ✗          | 0/12        | 0/16       |

**Key findings:**
- ✅ Basic + Standard SKUs (12 each) available in **every** NA region — no AI Search "capacity" issue at all on this tenant.
- ❌ `Standard2`, `Standard3`, `StorageOptimized` blocked (`limit:0`) in **every** region — these need an explicit Microsoft quota increase request, regardless of region.
- 🆓 Free SKU (1 per region) available everywhere — useful for proof-of-concept testing.
- 📦 Enhanced Density (12 each) and Serverless (16 each) also available everywhere — these are paid SKUs that don't need pre-approval.

### Azure OpenAI — Model availability matrix

`✓` = model can be deployed in this region.  `✗` = model not offered here.  `—` = no Cognitive Services in region.

| Region          | gpt-5.4 | gpt-5.4-pro | gpt-5.4-mini | gpt-5.4-nano | gpt-5.3-codex | o3 | o3-pro | o3-mini | embed-3-large | embed-3-small | gpt-image-1 |
|-----------------|---------|-------------|--------------|--------------|---------------|----|--------|---------|---------------|---------------|-------------|
| eastus          | ✓       | ✗           | ✓            | ✓            | ✓             | ✓  | ✗      | ✓       | ✓             | ✓             | ✗           |
| **eastus2**     | ✓       | **✓**       | ✓            | ✓            | ✓             | ✓  | **✓**  | ✓       | ✓             | ✓             | **✓**       |
| westus          | ✓       | ✗           | ✓            | ✓            | ✓             | ✓  | ✗      | ✓       | ✓             | ✓             | ✗           |
| westus2         | ✗       | ✗           | ✗            | ✗            | ✗             | ✓  | ✗      | ✗       | ✗             | ✗             | ✗           |
| westus3         | ✓       | ✗           | ✓            | ✓            | ✓             | ✓  | ✗      | ✓       | ✓             | ✓             | ✓           |
| centralus       | ✓       | ✗           | ✓            | ✓            | ✓             | ✓  | ✓      | ✓       | ✓             | ✓             | ✗           |
| northcentralus  | ✓       | ✗           | ✓            | ✓            | ✓             | ✓  | ✗      | ✓       | ✓             | ✓             | ✗           |
| southcentralus  | ✓       | ✓           | ✓            | ✓            | ✓             | ✓  | ✗      | ✓       | ✓             | ✓             | ✗           |
| canadacentral   | ✓       | ✗           | ✓            | ✓            | ✓             | ✓  | ✗      | ✓       | ✗             | ✗             | ✗           |
| canadaeast      | ✓       | ✗           | ✓            | ✓            | ✓             | ✓  | ✗      | ✓       | ✓             | ✓             | ✗           |
| mexicocentral   | —       | —           | —            | —            | —             | —  | —      | —       | —             | —             | —           |

**Key findings:**
- 🥇 **`eastus2` is the powerhouse** — only NA region with the full lineup including `gpt-5.4-pro`, `o3-pro`, AND `gpt-image-1`. If you're picking one region for an "everything" deployment, this is it.
- 🚫 **`westus2` is locked down** — only `o3` is available; ALL other models excluded. If a customer's deployment fails there, the model isn't supported in that region (not a quota issue).
- 🌎 **`mexicocentral`** has Microsoft.CognitiveServices completely unprovisioned — no OpenAI at all (despite AI Search being available).
- 🇨🇦 **Canada Central** missing embeddings — useful for Canadian data residency but you'd need to deploy embeddings to canadaeast separately.
- 🖼️ **`gpt-image-1` is rare** — only `eastus2` and `westus3` in NA. Check before architecting around image generation.
- 🧠 **`gpt-5.4-pro` is rarer** — only `eastus2` and `southcentralus`.
- 🦾 **`o3-pro` is rarest** — only `eastus2` and `centralus`.

### Azure OpenAI — TPM quota (max GlobalStandard limit per model)

`used/limit` in **K TPM** (1K = 1,000 tokens per minute).  `—` = model not offered.

| Region          | gpt-5.4 | gpt-5.4-pro | gpt-5.4-mini | gpt-5.4-nano | gpt-5.3-codex | o3        | o3-pro  | o3-mini    | embed-3-large | gpt-image-1 |
|-----------------|---------|-------------|--------------|--------------|---------------|-----------|---------|------------|---------------|-------------|
| eastus          | 0/1000K | —           | 0/1000K      | 0/5000K      | 0/1000K       | 0/100000K | —       | 0/1000000K | 0/1000K       | —           |
| **eastus2**     | **700/1000K** | 160/160K | 400/1000K | 400/5000K | 30/1000K | 200/100000K | 30/160K | 0/1000000K | 1/1000K | 1/3K |
| westus          | 0/1000K | —           | 0/1000K      | 0/5000K      | 0/1000K       | 0/100000K | —       | 0/1000000K | 0/1000K       | —           |
| westus2         | —       | —           | —            | —            | —             | —         | —       | —          | —             | —           |
| westus3         | 0/1000K | —           | 0/1000K      | 0/5000K      | 0/1000K       | 0/100000K | —       | 0/1000000K | 0/1000K       | 0/3K        |
| centralus       | 0/1000K | —           | 0/1000K      | 0/5000K      | 0/1000K       | 0/100000K | 0/160K  | 0/1000000K | 0/1000K       | —           |
| northcentralus  | 0/1000K | —           | 0/1000K      | 0/5000K      | 0/1000K       | 0/100000K | —       | 0/1000000K | 0/1000K       | —           |
| southcentralus  | 0/1000K | 0/160K      | 0/1000K      | 0/5000K      | 0/1000K       | 0/100000K | —       | 0/1000000K | 0/1000K       | —           |
| canadacentral   | 0/1000K | —           | 0/1000K      | 0/5000K      | 0/1000K       | —         | —       | —          | —             | —           |
| canadaeast      | 0/1000K | —           | 0/1000K      | 0/5000K      | 0/1000K       | 0/100000K | —       | 0/1000000K | 0/1000K       | —           |

**Quota observations:**
- **Active deployment in eastus2** — 700K of 1M gpt-5.4 TPM in use, 400K of mini, 30K of o3-pro. Real working deployment.
- **All other NA regions have 0% utilization** — quota is allocated but unused.
- **gpt-5.4 default quota is 1M TPM** — generous default for new deployments in qualifying regions.
- **gpt-5.4-pro and o3-pro have only 160K TPM** — much tighter, and only in 1-2 regions.
- **`o3-mini` shows 1B TPM quota** — that's the published default; in practice, you'll hit RPM limits first.
- **gpt-image-1 quota is only 3K** — single-digit images per minute, plan accordingly.

### Practical takeaways for the original problem

> "Customer tried to deploy AI Search in eastus on a fresh subscription and it failed."

Looking at the FDPO data above, **AI Search Basic/Standard is wide-open in every NA region** (0/12 used, 12 limit). So the failure was almost certainly NOT a regional capacity issue — it was likely:

1. **Provider not registered** on the new subscription → `az provider register --namespace Microsoft.Search`
2. **Tenant policy** blocking specific regions (run sweep against the customer's actual sub to confirm)
3. **They tried Standard2 or higher** (limit:0 everywhere by default — needs quota request)
4. **Subscription type** restriction (Free/student tiers can't deploy paid SKUs)

The script makes this diagnosable in seconds rather than guessing.

---

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
