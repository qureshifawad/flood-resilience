# US Flood Vulnerability Solution — Snowflake Summit 2026 HOL

An end-to-end flood vulnerability analysis platform built on Snowflake, combining open geospatial data from Overture Maps, FEMA risk indices, and CDC social vulnerability data to identify at-risk buildings across Louisiana.

## What You Will Build

- A geospatial pipeline identifying **3.56M Louisiana buildings** within FEMA flood zones
- A **social vulnerability overlay** linking flood exposure to community resilience
- **Cortex AI document intelligence** to parse Louisiana's State Hazard Mitigation Plan
- A **Cortex Agent** that answers questions using both structured data AND policy documents
- An interactive **Streamlit dashboard** with map visualizations and AI Q&A

## Snowflake Features Covered

| Feature | Purpose |
|---|---|
| Snowflake Marketplace | Overture Maps Buildings (2.3B global footprints) |
| Geospatial + H3 Functions | Spatial joins, hexagonal risk mapping |
| Internal Stages | Loading FEMA NRI + CDC SVI CSV data |
| Cortex PARSE_DOCUMENT | Extracting text from flood policy PDFs |
| Cortex Search | Semantic search over policy documents |
| Cortex COMPLETE | AI-generated risk summaries |
| Cortex Agent | Unified Q&A over structured data + unstructured documents |
| Streamlit in Snowflake | Interactive 4-tab vulnerability dashboard |
| Dynamic Tables | Auto-refreshing risk alert pipeline |

---

## Repository Structure

```
flood-resilience/
├── notebooks/
│   └── flood_vulnerability_hol.ipynb   ← Main HOL notebook (Labs 1-8)
├── streamlit/
│   └── flood_dashboard.py              ← Streamlit app (4 tabs)
├── semantic_model/
│   └── flood_risk_model.yaml           ← Semantic model for Cortex Analyst
├── agent/
│   ├── flood_risk_agent_spec.json      ← Cortex Agent spec (structured + unstructured)
│   └── create_agent.sql               ← SQL to create the agent
├── data/
│   ├── fema_nri/
│   │   └── NRI_CensusTracts_Louisiana.csv   ← FEMA National Risk Index (1,376 tracts)
│   ├── cdc_svi/
│   │   └── SVI_2022_LA.csv                  ← CDC Social Vulnerability Index (1,379 tracts)
│   ├── parish_centroids/
│   │   └── LA_Parish_Centroids.csv          ← 64 Louisiana parish centroids (lat/lon)
│   └── policy_docs/
│       ├── Louisiana_Hazard_Mitigation_Plan_2024_Intro.pdf
│       └── Louisiana_Hazard_Mitigation_Plan_2024_Strategies.pdf
```

---

## Quick Start (Step by Step)

### Prerequisites

- Snowflake account with **ACCOUNTADMIN** role (trial accounts work)
- A web browser (Chrome recommended)

---

### Step 1 — Install Overture Maps Buildings from Marketplace

This gives you access to 2.3 billion building footprints worldwide.

1. Log in to **Snowsight** (https://app.snowflake.com)
2. Click **Data Products** in the left sidebar
3. Click **Marketplace**
4. In the search bar, type **"Overture Maps - Buildings"**
5. Find the listing by **CARTO** and click on it
6. Click the blue **Get** button (top right)
7. In the dialog, click on options and then set the database name to **`OVERTURE_MAPS_BUILDINGS`**
8. In the roles dropdown, select **PUBLIC**
9. Click **Get** again to confirm
10. Wait for the share to be mounted (takes ~30 seconds)

> **How to verify:** Go to **Data → Databases** in the left sidebar. You should see `OVERTURE_MAPS_BUILDINGS` listed.

---

### Step 2 — Import the Notebook

1. In Snowsight, click **Projects** in the left sidebar
2. Click **Notebooks**
3. Click the **+ → Import .ipynb file** button (top right)
4. Browse to `notebooks/flood_vulnerability_hol.ipynb` from this repo
5. In the dialog:
   - Set **Database** = `FLOOD_ANALYTICS` (it will be created by the notebook)
   - Set **Schema** = `FLOOD`
6. Click **Create**

> **Tip:** You can also create a SQL Worksheet and run the notebook cells manually if you prefer.

---

### Step 3 — Upload Data Files to Snowflake Stages

After running the first two cells in the notebook (which create the database and stage), you need to upload the CSV and PDF files.

**Upload CSVs:**

1. In Snowsight, click **Data** in the left sidebar
2. Click **Add Data** (top right)
3. Click **Load files into a Stage**
4. Select database: `FLOOD_ANALYTICS`, schema: `FLOOD`, stage: `FLOOD_DATA_STAGE`
5. Upload the following files to these paths:

| File from this repo | Upload to stage path |
|---|---|
| `data/fema_nri/NRI_CensusTracts_Louisiana.csv` | `nri/` |
| `data/cdc_svi/SVI_2022_LA.csv` | `svi/` |
| `data/parish_centroids/LA_Parish_Centroids.csv` | `parish/` |
| `semantic_model/flood_risk_model.yaml` | `semantic/` |

**Upload PDFs:**

6. Go back to **Data → Add Data → Load files into a Stage**
7. Select stage: `FLOOD_POLICY_DOCS`
8. Upload both files from `data/policy_docs/`:
   - `Louisiana_Hazard_Mitigation_Plan_2024_Intro.pdf`
   - `Louisiana_Hazard_Mitigation_Plan_2024_Strategies.pdf`

> **How to verify:** Run `LIST @FLOOD_DATA_STAGE;` in a worksheet — you should see files in nri/, svi/, parish/, and semantic/ folders.

---

### Step 4 — Run the Notebook (Labs 1-8)

Run cells sequentially using **Shift+Enter**. The notebook is organized into 8 labs:

| Lab | What It Does | Expected Time |
|---|---|---|
| Lab 1 | Creates database, schema, warehouse; extracts 3.56M LA buildings | 5-8 min |
| Lab 2 | Loads FEMA NRI, CDC SVI, derives flood zones | 2-3 min |
| Lab 3 | Spatial joins: buildings → parishes → risk scores | 5-8 min |
| Lab 4 | Creates Dynamic Table for auto-refreshing risk alerts | 1 min |
| Lab 5 | Parses policy PDFs, chunks text, creates Cortex Search | 2-3 min |
| Lab 6 | Verifies tables for Cortex Analyst | 1 min |
| Lab 7 | Verification for Streamlit dashboard | 1 min |
| Lab 8 | Cleanup (optional — only run when done) | — |

> **Total runtime: ~20-25 minutes** (most time is the building extraction in Lab 1)

---

### Step 5 — Deploy the Streamlit Dashboard

1. In Snowsight, click **Projects** in the left sidebar
2. Click **Streamlit**
3. Click **+ Streamlit App** (top right)
4. Set:
   - **App name**: `Flood Vulnerability Dashboard`
   - **Database**: `FLOOD_ANALYTICS`
   - **Schema**: `FLOOD`
   - **Warehouse**: `FLOOD_WH`
5. Delete the template code in the editor
6. Paste the entire contents of `streamlit/flood_dashboard.py` from this repo
7. Click **Run** (top right)

**What you'll see — 4 tabs:**

| Tab | Content |
|---|---|
| Parish Overview | Risk league table with composite scores, bar chart of top 15 |
| Building Explorer | Interactive map of at-risk buildings, filterable by parish and score |
| H3 Heatmap | Hexagonal vulnerability heatmap data (table + risk distribution chart) |
| AI Insights | Ask Cortex AI any question about flood risk; see key statistics |

**Try these questions in the AI Insights tab:**
- *"Which parish has the highest percentage of buildings in flood zones?"*
- *"What is the total expected annual loss for the top 5 most vulnerable parishes?"*
- *"How does social vulnerability correlate with flood exposure?"*

---

### Step 6 — Use Cortex Analyst (Structured Data Q&A)

Cortex Analyst lets you ask natural language questions that automatically generate SQL.

1. In Snowsight, click **AI & ML** in the left sidebar
2. Click **Cortex Analyst**
3. Click **+ New Chat** (or **New Conversation**)
4. When prompted to select a semantic model, choose:
   - **Stage**: `@FLOOD_ANALYTICS.FLOOD.FLOOD_DATA_STAGE/semantic/flood_risk_model.yaml`
5. Start asking questions!

**Try these questions:**
- *"Which parish has the highest composite flood vulnerability score?"*
- *"How many buildings are in FEMA Special Flood Hazard Areas by parish?"*
- *"What is the total expected annual loss statewide?"*
- *"Which parishes have both high social vulnerability (SVI > 0.7) and high flood exposure?"*
- *"How many hospitals and schools are in flood zones?"*

> **What happens:** Cortex Analyst reads the semantic model, understands your table structure, and generates SQL to answer your question. You'll see both the SQL and the results.

---

### Step 7 — Deploy the Cortex Agent (Structured + Unstructured Q&A)

The Cortex Agent is the most powerful interface — it combines **structured data** (building counts, risk scores, parish statistics) with **unstructured policy documents** (mitigation plans, historical events, levee projects) in a single conversational experience.

**Create the agent:**

1. In Snowsight, click **Projects** in the left sidebar
2. Click **Worksheets** → **+ SQL Worksheet**
3. Paste the entire contents of `agent/create_agent.sql` from this repo
4. Click **Run All** (or select all and press Ctrl+Enter)
5. You should see: `Agent FLOOD_RISK_AGENT successfully created.`

**Use the agent:**

6. In Snowsight, click **AI & ML** in the left sidebar
7. Click **Snowflake Intelligence** (or **Agents**)
8. You should see `FLOOD_RISK_AGENT` listed — click on it
9. Start a conversation!

**Try these questions (the agent will automatically choose the right tool):**

| Question | Tools Used | What You Get |
|---|---|---|
| *"Which 5 parishes have the highest flood vulnerability?"* | Structured data | Parish rankings with scores |
| *"What does the state mitigation plan say about levee projects?"* | Policy docs | Relevant excerpts from the PDF |
| *"Which parishes are most at risk and what federal programs can help them?"* | Both tools | Data-driven risk ranking + policy context |
| *"What happened during Hurricane Katrina and how many buildings are still in flood zones?"* | Both tools | Historical context + current exposure stats |
| *"What mitigation strategies are planned for coastal Louisiana?"* | Policy docs | State plan strategies and projects |
| *"Compare the social vulnerability of Orleans Parish vs Jefferson Parish"* | Structured data | SVI scores and building exposure side-by-side |

> **How it works:** The agent has two tools:
> - **query_flood_data** — generates SQL queries against your 3.56M building database
> - **search_policy_docs** — searches through the parsed Louisiana Hazard Mitigation Plan PDFs
>
> It automatically decides which tool to use (or both) based on your question.

---

## Data Sources

| Dataset | Source | License |
|---|---|---|
| Overture Maps Buildings | CARTO / Overture Maps Foundation | ODbL |
| FEMA National Risk Index | hazards.fema.gov | Public Domain |
| CDC Social Vulnerability Index 2022 | atsdr.cdc.gov | Public Domain |
| Louisiana State Hazard Mitigation Plan 2024 | gohsep.la.gov | Public Domain |

---

## Architecture

```
MARKETPLACE              STAGES                     CORTEX AI
Overture Maps     →   FEMA NRI CSV          →   PARSE_DOCUMENT
Buildings         →   CDC SVI CSV           →   Cortex Search
                  →   Policy PDFs           →   Cortex COMPLETE
        ↓                  ↓                          ↓
              FLOOD_ANALYTICS.FLOOD schema
        ┌──────────────────────────────────┐
        │ BUILDINGS_LA    FEMA_NRI         │
        │ CDC_SVI         FLOOD_ZONES      │
        │ BUILDING_FLOOD_RISK              │
        │ PARISH_FLOOD_SUMMARY             │
        │ H3_FLOOD_RISK_MAP                │
        │ FLOOD_RISK_ALERTS (Dynamic TBL)  │
        └──────────────────────────────────┘
                          ↓
              ┌────────────────────────┐
              │   CORTEX AGENT         │
              │   (FLOOD_RISK_AGENT)   │
              │                        │
              │  Tool 1: Analyst       │
              │  (structured SQL)      │
              │                        │
              │  Tool 2: Search        │
              │  (policy documents)    │
              └────────────────────────┘
                          ↓
              STREAMLIT DASHBOARD
              SNOWFLAKE INTELLIGENCE
```

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `Database 'OVERTURE_MAPS_BUILDINGS' does not exist` | Go to Marketplace and install "Overture Maps - Buildings" by CARTO |
| `COPY INTO fails with column count mismatch` | The notebook uses `PARSE_HEADER = TRUE` and `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE` — make sure you ran the CSV_FORMAT cell first |
| `Agent says "search_service not provided"` | Make sure you're using the latest `create_agent.sql` — the field must be `search_service` not `cortex_search_service` |
| `Cortex Search returns no results` | Run `ALTER STAGE FLOOD_POLICY_DOCS REFRESH;` then wait 60 seconds for indexing |
| `H3_CELL_TO_BOUNDARY_WKT not found` | Use `ST_ASWKT(H3_CELL_TO_BOUNDARY(...))` instead — the notebook has been fixed |
| `SVI shows negative values (-999)` | These are CDC sentinel values — the notebook filters them with `CASE WHEN >= 0` |

---

## Lab Overview

| Lab | Topic | Time |
|---|---|---|
| 1 | Environment setup + Overture Buildings extraction | 10 min |
| 2 | Load FEMA NRI + CDC SVI + derive Flood Zones | 15 min |
| 3 | Geospatial flood risk analysis (H3 spatial joins) | 20 min |
| 4 | Dynamic Tables for automated risk alerts | 10 min |
| 5 | Cortex AI — parse policy PDFs + semantic search | 20 min |
| 6 | Cortex Analyst — natural language data Q&A | 5 min |
| 7 | Streamlit dashboard deployment | 10 min |
| 8 | Cleanup (optional) | — |

**Total: ~90 minutes**

---

*Built for Snowflake Summit 2026 | Data: Overture Maps / CARTO · FEMA NRI · CDC SVI · Louisiana GOHSEP*
