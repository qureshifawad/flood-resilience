---
name: deploy-streamlit-flood-dashboard
description: Deploy the Streamlit flood vulnerability dashboard with pydeck maps, altair charts, and Snowflake brand styling. Use when deploying, redeploying, or updating the Streamlit app from the workspace.
---

# Deploy Streamlit Flood Dashboard

This skill deploys the interactive Streamlit flood vulnerability dashboard to Snowflake with pydeck building polygons, H3 hexagonal heatmap, altair charts, and Snowflake brand styling.

## Prerequisites

- Database `FLOOD_ANALYTICS` and schema `FLOOD` must exist
- Warehouse `FLOOD_WH` must exist
- Tables required: `PARISH_FLOOD_SUMMARY`, `BUILDING_FLOOD_RISK`, `BUILDINGS_LA`, `H3_FLOOD_RISK_MAP`
- Role must have CREATE STREAMLIT and CREATE STAGE privileges

## Files to Deploy

The app consists of 3 files in the `streamlit/` directory:

### `streamlit/flood_dashboard.py`

Must include:
- `import pydeck as pdk` and `import altair as alt`
- 4 tabs: Parish Overview, Building Explorer, H3 Heatmap, AI Insights
- **Snowflake brand colours**: `#29B5E8` (cyan accent), `#11567F` (dark blue), `#6E7681` (grey), `#E4584F` (alert red)

### `streamlit/environment.yml`

```yaml
name: sf_env
channels:
  - snowflake
dependencies:
  - pandas
  - pydeck
  - plotly
  - altair
```

### `streamlit/.streamlit/config.toml`

```toml
[theme]
primaryColor = "#29B5E8"
backgroundColor = "#FFFFFF"
secondaryBackgroundColor = "#F4F7FA"
textColor = "#11567F"
font = "sans serif"
```

## Key Implementation Details

### Building Explorer — Pydeck PolygonLayer (NOT GeoJsonLayer)

CRITICAL: Use `PolygonLayer` with a flat dataframe — NOT `GeoJsonLayer`. This is because Streamlit's pydeck tooltip `{field}` syntax only resolves fields from the dataframe columns, not from nested GeoJSON properties.

```python
geo_df["coordinates"] = geo_df["GEOJSON"].apply(lambda g: json.loads(g)["coordinates"])
# Add tooltip columns as flat dataframe columns
geo_df["name"] = geo_df["BUILDING_NAME"].fillna("Unknown")
geo_df["vuln"] = geo_df["COMPOSITE_VULNERABILITY_SCORE"].round(1)

polygon_layer = pdk.Layer(
    "PolygonLayer",
    geo_df[["coordinates", "color_r", "color_g", "name", "vuln", "zone", "bclass", "par"]],
    get_polygon="coordinates",
    get_fill_color="[color_r, color_g, 60, 200]",
    pickable=True,
    extruded=False,
)

tooltip = {
    "text": "Building: {name}\nClass: {bclass}\nParish: {par}\nFlood Zone: {zone}\nVulnerability: {vuln}",
    ...
}
```

The geometry comes from `BUILDINGS_LA.GEOMETRY` (GEOGRAPHY type) via:
```sql
ST_ASGEOJSON(b.GEOMETRY) AS GEOJSON
FROM BUILDING_FLOOD_RISK r
JOIN BUILDINGS_LA b ON r.BUILDING_ID = b.ID
```

### H3 Heatmap — H3HexagonLayer (2D, flat)

- Use uppercase column names in the dataframe (`COLOR_R`, `COLOR_G`, `COLOR_B`)
- `extruded=False`, `pitch=0` for flat 2D rendering
- Tooltip uses `"text"` format (NOT `"html"`) with `{COLUMN_NAME}` matching dataframe columns exactly

### Charts — Altair (NOT st.bar_chart)

- Parish bar chart with gradient fill and interactive tooltips
- Bubble scatter plot (NRI vs SVI)
- Vulnerability histogram in Building Explorer
- Donut chart for H3 risk distribution

### Streamlit API Limitations (Snowflake Runtime)

- `st.pydeck_chart()` does NOT support `height` kwarg — omit it
- `st.map()` does NOT support `latitude`/`longitude` kwargs — use pydeck instead
- `st.set_page_config()` must be first Streamlit command

## Deploy via SQL

```sql
CREATE OR REPLACE STAGE FLOOD_ANALYTICS.FLOOD.STREAMLIT_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

COPY FILES INTO @FLOOD_ANALYTICS.FLOOD.STREAMLIT_STAGE/
FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/'
FILES=('streamlit/flood_dashboard.py', 'streamlit/environment.yml', 'streamlit/.streamlit/config.toml');

CREATE OR REPLACE STREAMLIT FLOOD_ANALYTICS.FLOOD.FLOOD_VULNERABILITY_DASHBOARD
  ROOT_LOCATION  = '@FLOOD_ANALYTICS.FLOOD.STREAMLIT_STAGE/streamlit'
  MAIN_FILE      = 'flood_dashboard.py'
  QUERY_WAREHOUSE = FLOOD_WH
  TITLE          = 'Flood Vulnerability Dashboard';
```

## Verify Deployment

```sql
SHOW STREAMLITS LIKE 'FLOOD_VULNERABILITY_DASHBOARD' IN SCHEMA FLOOD_ANALYTICS.FLOOD;
```

## Data Quality Notes

- `PARISH_FLOOD_SUMMARY.PCT_IN_SFHA`: Must be calculated from tract-level `FLOOD_ZONES` table (not the parish-level `IN_SPECIAL_FLOOD_HAZARD_AREA` boolean which is the same for all buildings in a parish)
- `PARISH_FLOOD_SUMMARY.TOTAL_EXPECTED_ANNUAL_LOSS`: Must use `MAX()` not `SUM()` — the EAL value is parish-level and duplicated across all buildings in a parish

## Troubleshooting

- **Tooltips show `{field}` as literal text**: You are using GeoJsonLayer — switch to PolygonLayer with flat dataframe
- **`st.pydeck_chart() got unexpected keyword argument 'height'`**: Remove `height` param
- **`TypeError: MapMixin.map() got unexpected keyword argument 'latitude'`**: Use pydeck instead of st.map
- **All parishes show 100% flood zone**: Recalculate from tract-level FLOOD_ZONES, not parish-level boolean
- **Annual loss in trillions**: You used SUM instead of MAX on the parish-level EAL
- **Stage copy fails**: Verify workspace name matches `USER$.PUBLIC."flood-resilience"`
