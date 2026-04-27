import streamlit as st
from snowflake.snowpark.context import get_active_session
import pandas as pd

session = get_active_session()

st.set_page_config(page_title="Louisiana Flood Vulnerability", page_icon="🌊", layout="wide")
st.title("🌊 Louisiana Flood Vulnerability Dashboard")
st.caption("Powered by Snowflake | FEMA NRI · CDC SVI · Overture Maps Buildings · Cortex AI")

tab1, tab2, tab3, tab4 = st.tabs(["Parish Overview", "Building Explorer", "H3 Heatmap", "AI Insights"])


@st.cache_data(ttl=300)
def load_parish_summary():
    return session.sql("""
        SELECT PARISH, TOTAL_BUILDINGS, BUILDINGS_IN_SFHA, PCT_IN_SFHA,
               AVG_NRI_RISK_SCORE, AVG_SVI_SCORE, AVG_COMPOSITE_SCORE,
               TOTAL_EXPECTED_ANNUAL_LOSS, BUILDING_EXPECTED_ANNUAL_LOSS,
               BUILDINGS_COASTAL_ZONE, BUILDINGS_RIVERINE_ZONE
        FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY
        ORDER BY AVG_COMPOSITE_SCORE DESC
    """).to_pandas()


df_parish = load_parish_summary()


# ── TAB 1: Parish Overview ────────────────────────────────────────────────────
with tab1:
    st.subheader("Parish-Level Flood Risk Summary")

    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Parishes", f"{len(df_parish)}")
    col2.metric("Total Buildings", f"{df_parish['TOTAL_BUILDINGS'].sum():,.0f}")
    col3.metric("In Flood Zones", f"{df_parish['BUILDINGS_IN_SFHA'].sum():,.0f}")
    col4.metric("Statewide Annual Loss", f"${df_parish['TOTAL_EXPECTED_ANNUAL_LOSS'].sum():,.0f}")

    st.markdown("---")

    display = df_parish.copy()
    display["TOTAL_EXPECTED_ANNUAL_LOSS"] = display["TOTAL_EXPECTED_ANNUAL_LOSS"].apply(
        lambda x: f"${x:,.0f}" if pd.notna(x) else "N/A"
    )
    display["PCT_IN_SFHA"] = display["PCT_IN_SFHA"].apply(
        lambda x: f"{x:.1f}%" if pd.notna(x) else "N/A"
    )

    st.dataframe(
        display.rename(columns={
            "PARISH": "Parish", "TOTAL_BUILDINGS": "Buildings",
            "BUILDINGS_IN_SFHA": "In Flood Zone", "PCT_IN_SFHA": "% in Flood Zone",
            "AVG_NRI_RISK_SCORE": "NRI Risk Score", "AVG_SVI_SCORE": "SVI Score",
            "AVG_COMPOSITE_SCORE": "Composite Score",
            "TOTAL_EXPECTED_ANNUAL_LOSS": "Annual Loss Exposure",
        }).drop(columns=["BUILDING_EXPECTED_ANNUAL_LOSS", "BUILDINGS_COASTAL_ZONE", "BUILDINGS_RIVERINE_ZONE"]),
        use_container_width=True, height=450
    )

    st.markdown("**Top 15 Parishes — % Buildings in Flood Zones**")
    st.bar_chart(df_parish.head(15).set_index("PARISH")["PCT_IN_SFHA"], use_container_width=True, height=300)


# ── TAB 2: Building Explorer ──────────────────────────────────────────────────
with tab2:
    st.subheader("Explore At-Risk Buildings by Parish")

    col_a, col_b = st.columns(2)
    with col_a:
        parishes = ["(All)"] + sorted(df_parish["PARISH"].dropna().tolist())
        selected_parish = st.selectbox("Select Parish", parishes)
    with col_b:
        risk_threshold = st.slider("Minimum Composite Vulnerability Score", 0, 100, 50, step=5)

    @st.cache_data(ttl=60)
    def load_buildings(parish, threshold):
        where_parish = f"AND PARISH = '{parish}'" if parish != "(All)" else ""
        return session.sql(f"""
            SELECT BUILDING_NAME, CLASS, FLOOD_ZONE, ZONE_DESCRIPTION,
                   COMPOSITE_VULNERABILITY_SCORE, NRI_RISK_SCORE,
                   SVI_OVERALL, EXPECTED_ANNUAL_LOSS, LATITUDE, LONGITUDE, PARISH
            FROM FLOOD_ANALYTICS.FLOOD.BUILDING_FLOOD_RISK
            WHERE COMPOSITE_VULNERABILITY_SCORE >= {threshold}
              {where_parish}
            ORDER BY COMPOSITE_VULNERABILITY_SCORE DESC
            LIMIT 2000
        """).to_pandas()

    df_bldg = load_buildings(selected_parish, risk_threshold)
    label = f"in {selected_parish}" if selected_parish != "(All)" else "statewide"
    st.metric(f"Buildings {label} above threshold", f"{len(df_bldg):,}")

    if not df_bldg.empty:
        map_df = df_bldg[["LATITUDE", "LONGITUDE"]].dropna()
        if not map_df.empty:
            st.map(map_df, latitude="LATITUDE", longitude="LONGITUDE", zoom=7)

        st.dataframe(
            df_bldg.head(200).rename(columns={
                "BUILDING_NAME": "Name", "CLASS": "Type", "FLOOD_ZONE": "Zone",
                "COMPOSITE_VULNERABILITY_SCORE": "Vuln Score", "NRI_RISK_SCORE": "NRI Score",
                "SVI_OVERALL": "SVI", "EXPECTED_ANNUAL_LOSS": "Annual Loss", "PARISH": "Parish"
            }).drop(columns=["ZONE_DESCRIPTION", "LATITUDE", "LONGITUDE"], errors="ignore"),
            use_container_width=True, height=300
        )
    else:
        st.info("No buildings found matching the selected criteria.")


# ── TAB 3: H3 Heatmap ────────────────────────────────────────────────────────
with tab3:
    st.subheader("H3 Hexagonal Vulnerability Heatmap")
    st.markdown("Each hexagon = H3 resolution-6 cell (~36 km across). Colour reflects **avg composite vulnerability score**.")

    @st.cache_data(ttl=300)
    def load_h3():
        return session.sql("""
            SELECT H3_INDEX_6, BUILDING_COUNT, BUILDINGS_AT_RISK,
                   AVG_VULNERABILITY, AVG_NRI_SCORE, AVG_SVI, TOTAL_EAL, PRIMARY_PARISH
            FROM FLOOD_ANALYTICS.FLOOD.H3_FLOOD_RISK_MAP
            ORDER BY AVG_VULNERABILITY DESC
            LIMIT 500
        """).to_pandas()

    df_h3 = load_h3()
    c1, c2 = st.columns(2)

    with c1:
        st.markdown("**Top 20 Highest-Risk Hexagons**")
        st.dataframe(
            df_h3.head(20).rename(columns={
                "H3_INDEX_6": "H3 Cell", "PRIMARY_PARISH": "Parish",
                "BUILDING_COUNT": "Buildings", "BUILDINGS_AT_RISK": "At Risk",
                "AVG_VULNERABILITY": "Avg Vuln", "AVG_SVI": "Avg SVI", "TOTAL_EAL": "Total EAL"
            }),
            use_container_width=True, height=400
        )

    with c2:
        st.markdown("**Risk Distribution**")
        if not df_h3.empty:
            bins = pd.cut(df_h3["AVG_VULNERABILITY"], bins=[0, 25, 50, 75, 100],
                          labels=["Low", "Moderate", "High", "Critical"])
            st.bar_chart(bins.value_counts().sort_index(), use_container_width=True)
            st.markdown(f"""
**Summary**
- Hexagons: {len(df_h3):,}
- Avg vulnerability: {df_h3['AVG_VULNERABILITY'].mean():.1f}
- Max vulnerability: {df_h3['AVG_VULNERABILITY'].max():.1f}
            """)


# ── TAB 4: AI Insights ───────────────────────────────────────────────────────
with tab4:
    st.subheader("Ask Cortex AI About Flood Risk")
    st.markdown("Ask any question about Louisiana flood vulnerability.  \nPowered by **Snowflake Cortex COMPLETE**.")

    for q in [
        "Which parish has the highest percentage of buildings in flood zones?",
        "What is the total expected annual loss for the top 5 most vulnerable parishes?",
        "How does social vulnerability correlate with flood exposure?",
        "Which parishes should be prioritised for emergency preparedness?",
        "What building types are most at risk in coastal flood zones?"
    ]:
        st.markdown(f"- *{q}*")

    user_question = st.text_input("Your question:", placeholder="e.g. Which parish has the most critical infrastructure at risk?")

    if st.button("Ask AI", type="primary") and user_question:
        safe_q = user_question.replace("'", "''")
        with st.spinner("Analysing with Cortex AI..."):
            result = session.sql(f"""
                SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.1-70b', CONCAT(
                    'You are a Louisiana flood risk expert. Answer concisely.\\n\\n',
                    'PARISH DATA:\\n',
                    (SELECT LISTAGG(PARISH||': composite='||AVG_COMPOSITE_SCORE||
                        ', SVI='||AVG_SVI_SCORE||', '||PCT_IN_SFHA||'% in flood zone'||
                        ', loss=$'||TOTAL_EXPECTED_ANNUAL_LOSS, '\\n')
                     FROM (SELECT * FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY
                           ORDER BY AVG_COMPOSITE_SCORE DESC LIMIT 20)),
                    '\\n\\nQUESTION: {safe_q}\\nANSWER:')) AS ANSWER
            """).to_pandas()
            st.success("**AI Response:**")
            st.write(result["ANSWER"].iloc[0])

    st.markdown("---")
    st.subheader("Key Statistics")

    @st.cache_data(ttl=300)
    def load_kpis():
        return session.sql("""
            SELECT
              (SELECT PARISH FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY ORDER BY AVG_COMPOSITE_SCORE DESC LIMIT 1) AS MOST_VULNERABLE,
              (SELECT PARISH FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY ORDER BY PCT_IN_SFHA DESC LIMIT 1) AS MOST_IN_FLOOD_ZONE,
              (SELECT PARISH FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY ORDER BY AVG_SVI_SCORE DESC LIMIT 1) AS HIGHEST_SVI,
              (SELECT PARISH FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY ORDER BY TOTAL_EXPECTED_ANNUAL_LOSS DESC LIMIT 1) AS HIGHEST_EAL,
              (SELECT ROUND(SUM(TOTAL_EXPECTED_ANNUAL_LOSS),0) FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY) AS STATEWIDE_EAL,
              (SELECT SUM(BUILDINGS_IN_SFHA) FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY) AS TOTAL_SFHA_BLDGS
        """).to_pandas()

    kpis = load_kpis()
    k1, k2, k3 = st.columns(3)
    k4, k5, k6 = st.columns(3)
    k1.metric("Most Vulnerable Parish",       kpis["MOST_VULNERABLE"].iloc[0])
    k2.metric("Most in Flood Zone",           kpis["MOST_IN_FLOOD_ZONE"].iloc[0])
    k3.metric("Highest Social Vulnerability", kpis["HIGHEST_SVI"].iloc[0])
    k4.metric("Highest Annual Loss Parish",   kpis["HIGHEST_EAL"].iloc[0])
    k5.metric("Statewide Annual Loss",        f"${kpis['STATEWIDE_EAL'].iloc[0]:,.0f}")
    k6.metric("Buildings in Flood Zones",     f"{int(kpis['TOTAL_SFHA_BLDGS'].iloc[0]):,}")
