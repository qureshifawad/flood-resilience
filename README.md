# 🌊 US Flood Vulnerability Solution — Snowflake Summit 2026 HOL

An end-to-end flood vulnerability analysis platform built on Snowflake, combining open geospatial data from Overture Maps, FEMA risk indices, and CDC social vulnerability data to identify at-risk buildings across Louisiana.

## What You Will Build

- A geospatial pipeline identifying **3M+ Louisiana buildings** within FEMA flood zones
- A **social vulnerability overlay** linking flood exposure to community resilience
- **Cortex AI document intelligence** to parse Louisiana's State Hazard Mitigation Plan
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
| Streamlit in Snowflake | Interactive 4-tab vulnerability dashboard |
| Dynamic Tables | Auto-refreshing risk alert pipeline |

---

## Repository Structure

```
flood-resilience/
├── notebooks/
│   └── flood_vulnerability_hol.ipynb   ← Main HOL notebook (import into Snowflake Workspace)
├── streamlit/
│   └── flood_dashboard.py              ← Streamlit app (paste into Snowsight Streamlit)
├── semantic_model/
│   └── flood_risk_model.yaml           ← Semantic model for Cortex Analyst
├── agent/
│   ├── flood_risk_agent_spec.json      ← Cortex Agent specification (structured + unstructured)
│   └── create_agent.sql               ← SQL to create the agent in Snowflake
└── data/
    ├── fema_nri/
    │   └── NRI_CensusTracts_Louisiana.csv   ← FEMA National Risk Index (1,376 LA tracts)
    ├── cdc_svi/
    │   └── SVI_2022_LA.csv                  ← CDC Social Vulnerability Index 2022 (1,379 LA tracts)
    └── policy_docs/
        ├── Louisiana_Hazard_Mitigation_Plan_2024_Intro.pdf
        └── Louisiana_Hazard_Mitigation_Plan_2024_Strategies.pdf
```

---

## Quick Start

### Prerequisites
- Snowflake account with ACCOUNTADMIN role (trial accounts work)
- Overture Maps Buildings installed from Snowflake Marketplace

### Step 1 — Install Overture Maps Buildings from Marketplace

1. In Snowsight → **Data Products → Marketplace**
2. Search **"Overture Maps - Buildings"** by CARTO
3. Click **Get** → name the database **`OVERTURE_MAPS_BUILDINGS`**

### Step 2 — Import the Notebook into Snowflake Workspace

1. In Snowsight → **Projects → Notebooks**
2. Click **⊕ → Import .ipynb file**
3. Upload `notebooks/flood_vulnerability_hol.ipynb`
4. Set database: `FLOOD_ANALYTICS`, schema: `FLOOD`
5. Run cells sequentially (Shift+Enter)

### Step 3 — Upload Data Files to Snowflake Stage

After running the notebook setup cells (Lab 1), upload data files to the stage:

1. Snowsight → **Data → Add Data → Load files into a Stage**
2. Select stage `FLOOD_DATA_STAGE`
3. Upload `data/fema_nri/NRI_CensusTracts_Louisiana.csv` → path `nri/`
4. Upload `data/cdc_svi/SVI_2022_LA.csv` → path `svi/`
5. Upload `data/parish_centroids/LA_Parish_Centroids.csv` → path `parish/`
6. Upload the two PDFs from `data/policy_docs/` → stage `FLOOD_POLICY_DOCS`
7. Upload `semantic_model/flood_risk_model.yaml` → path `semantic/`

### Step 4 — Run the Notebook

Follow the notebook cells in order. Each cell has:
- Clear instructions in the markdown above it
- The expected output after running
- Time estimates for long-running queries

### Step 5 — Deploy the Streamlit Dashboard

1. Snowsight → **Streamlit → + Streamlit App**
2. Set database: `FLOOD_ANALYTICS`, schema: `FLOOD`
3. Paste contents of `streamlit/flood_dashboard.py`
4. Click **Run**

### Step 6 — Use Cortex Analyst

1. Upload `semantic_model/flood_risk_model.yaml` to `@FLOOD_DATA_STAGE/semantic/`
2. Snowsight → **AI & ML → Cortex Analyst → New Chat**
3. Select the YAML semantic model
4. Ask questions like *"Which parish has the highest social vulnerability?"*

### Step 7 — Deploy Cortex Agent (Structured + Unstructured)

1. Run `agent/create_agent.sql` in a SQL worksheet
2. Snowsight → **AI & ML → Snowflake Intelligence** → select `FLOOD_RISK_AGENT`
3. The agent combines both structured data AND policy documents:
   - *"Which parishes have the highest flood risk and what mitigation plans exist?"*
   - *"What does the state plan say about levee projects in coastal parishes?"*
   - *"How many buildings are at risk and what federal programs can help?"*

---

## Data Sources

| Dataset | Source | License |
|---|---|---|
| Overture Maps Buildings | CARTO / Overture Maps Foundation | ODbL |
| FEMA National Risk Index | hazards.fema.gov | Public Domain |
| CDC Social Vulnerability Index 2022 | atsdr.cdc.gov | Public Domain |
| Louisiana State Hazard Mitigation Plan 2024 | gohsep.la.gov | Public Domain |

---

## Lab Overview

| Lab | Topic | Time |
|---|---|---|
| 1 | Environment setup + Overture Buildings | 10 min |
| 2 | Load FEMA NRI + CDC SVI + Flood Zones | 15 min |
| 3 | Geospatial flood risk analysis (H3 joins) | 20 min |
| 4 | Dynamic Tables for risk alerts | 10 min |
| 5 | Cortex AI — parse policy PDFs + search | 20 min |
| 6 | Cortex Analyst semantic model | 5 min |
| 7 | Streamlit dashboard | 10 min |
| 8 | Cleanup | optional |

**Total: ~90 minutes**

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
              STREAMLIT DASHBOARD
              CORTEX ANALYST
```

---

*Built for Snowflake Summit 2026 | Data: Overture Maps / CARTO · FEMA NRI · CDC SVI · Louisiana GOHSEP*
