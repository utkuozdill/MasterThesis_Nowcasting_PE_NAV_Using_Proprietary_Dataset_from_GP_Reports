import pandas as pd
import numpy as np
from pathlib import Path

# =========================
# CONFIG
# =========================
FILE_PATH = "output_Studi 15 (Uktu Ö.).xlsx"
CLEAN_FUND_FILE = "CLEAN_fund.csv"
CLEAN_CF_FILE = "CLEAN_fund_cash_flow.csv"
CLEAN_CAP_FILE = "CLEAN_capital_account.csv"
OUTPUT_FILE = "dataset_summary_table.xlsx"
THESIS_SUBMISSION_DATE = pd.Timestamp("2026-04-15")

# =========================
# HELPERS
# =========================
def normalize_cols(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df.columns = [
        str(c).strip().lower().replace(" ", "_").replace("-", "_").replace("/", "_")
        for c in df.columns
    ]
    return df

def find_sheet(sheets_dict, candidates):
    normalized = {k.strip().lower(): k for k in sheets_dict.keys()}
    for cand in candidates:
        cand_norm = cand.strip().lower()
        for k_norm, k_orig in normalized.items():
            if cand_norm == k_norm:
                return sheets_dict[k_orig]
    # partial match fallback
    for cand in candidates:
        cand_norm = cand.strip().lower()
        for k_norm, k_orig in normalized.items():
            if cand_norm in k_norm:
                return sheets_dict[k_orig]
    return None

def find_col(df: pd.DataFrame, candidates):
    cols = list(df.columns)
    for cand in candidates:
        cand_norm = cand.strip().lower().replace(" ", "_").replace("-", "_").replace("/", "_")
        if cand_norm in cols:
            return cand_norm
    # partial match fallback
    for cand in candidates:
        cand_norm = cand.strip().lower().replace(" ", "_").replace("-", "_").replace("/", "_")
        for c in cols:
            if cand_norm == c or cand_norm in c:
                return c
    return None

def fmt_int(x):
    if pd.isna(x):
        return "N/A"
    return f"{int(round(x)):,}"

def fmt_num(x, digits=1):
    if pd.isna(x):
        return "N/A"
    return f"{x:,.{digits}f}"

def top_distribution(series, top_n=3, digits=1):
    s = series.dropna().astype(str).str.strip()
    if s.empty:
        return "N/A"
    vc = s.value_counts(normalize=True) * 100
    top = vc.head(top_n)
    return ", ".join([f"{idx} ({val:.{digits}f})" for idx, val in top.items()])

def numeric_summary(series, digits=1):
    s = pd.to_numeric(series, errors="coerce").dropna()
    if s.empty:
        return {"mean": np.nan, "median": np.nan, "std": np.nan, "min": np.nan, "max": np.nan}
    return {
        "mean": s.mean(),
        "median": s.median(),
        "std": s.std(),
        "min": s.min(),
        "max": s.max(),
    }

def infer_region_from_country_or_currency(df: pd.DataFrame, country_col: str | None, currency_col: str | None) -> pd.Series:
    out = pd.Series(index=df.index, dtype="object")

    # Step 1: use country when available
    if country_col and country_col in df.columns:
        country = df[country_col].astype(str).str.strip().str.upper()

        europe = {
            "AT", "BE", "BG", "CH", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GR", "HR",
            "HU", "IE", "IS", "IT", "LI", "LT", "LU", "LV", "MT", "NL", "NO", "PL", "PT", "RO",
            "SE", "SI", "SK"
        }
        uk = {"GB", "UK"}
        nordics = {"SE", "NO", "DK", "FI", "IS"}
        north_america = {"US", "CA"}
        asia = {"CN", "HK", "JP", "SG", "IN", "KR", "TW", "ID", "MY", "PH", "TH", "VN"}
        latin_america = {"MX", "BR", "AR", "CL", "CO", "PE"}
        middle_east = {"AE", "SA", "QA", "KW", "BH", "OM", "IL"}
        africa = {"ZA", "NG", "EG", "MA", "KE"}
        oceania = {"AU", "NZ"}

        out.loc[country.isin(nordics)] = "Nordics"
        out.loc[country.isin(uk)] = "United Kingdom"
        out.loc[country.isin(europe) & out.isna()] = "Europe"
        out.loc[country.isin(north_america)] = "North America"
        out.loc[country.isin(asia)] = "Asia"
        out.loc[country.isin(latin_america)] = "Latin America"
        out.loc[country.isin(middle_east)] = "Middle East"
        out.loc[country.isin(africa)] = "Africa"
        out.loc[country.isin(oceania)] = "Oceania"

    # Step 2: fallback to currency only for still-missing entries
    if currency_col and currency_col in df.columns:
        ccy = df[currency_col].astype(str).str.strip().str.upper()
        missing_mask = out.isna()

        out.loc[missing_mask & ccy.isin(["EUR"])] = "Europe"
        out.loc[missing_mask & ccy.isin(["GBP"])] = "United Kingdom"
        out.loc[missing_mask & ccy.isin(["SEK", "NOK", "DKK", "ISK"])] = "Nordics"
        out.loc[missing_mask & ccy.isin(["CHF"])] = "Europe"
        out.loc[missing_mask & ccy.isin(["CAD"])] = "North America"
        out.loc[missing_mask & ccy.isin(["AUD", "NZD"])] = "Oceania"
        out.loc[missing_mask & ccy.isin(["JPY", "CNY", "CNH", "HKD", "SGD", "INR", "KRW", "TWD"])] = "Asia"
        out.loc[missing_mask & ccy.isin(["USD"])] = "Global / Unclassified USD"

    return out


# =========================
# SUMMARY & COVERAGE TABLE HELPERS
# =========================

def build_summary_and_coverage_tables(
    fund_df: pd.DataFrame,
    cf_df: pd.DataFrame,
    cap_df: pd.DataFrame,
    deal_df: pd.DataFrame | None = None,
):
    # =========================
    # COLUMN DETECTION
    # =========================
    fund_id_col = find_col(fund_df, ["id", "fund_id"])
    gp_id_col = find_col(fund_df, ["general_partner_id", "gp_id", "general_partner", "gp"])
    fund_size_col = find_col(fund_df, [
        "fund_size",
        "size",
        "target_size",
        "fund_size_usd",
        "fund_size_(in_€m)",
        "fund_size_(in_usd_mn)",
        "size_of_fund",
        "fund_size_eur",
        "fund_size_usd",
        "fundsize"
    ])
    currency_col = find_col(fund_df, ["reported_currency", "currency", "reporting_currency"])
    country_col = find_col(fund_df, ["country", "country_code", "domicile_country", "fund_country", "gp_country"])

    cf_fund_id_col = find_col(cf_df, ["fund_id", "id"])
    cf_date_col = find_col(cf_df, ["cash_flow_date", "date"])
    cf_type_col = find_col(cf_df, ["cash_flow_type", "type"])
    cf_amount_col = find_col(cf_df, ["cash_flow", "cash_flow_amount", "amount"])

    cap_fund_id_col = find_col(cap_df, ["fund_id", "id"])
    cap_nav_col = find_col(cap_df, [
        "nav_after_carried_interest_at_reported_quarter",
        "nav_after_carried_interest",
        "reported_nav",
        "nav"
    ])

    deal_fund_id_col = None
    if deal_df is not None:
        deal_fund_id_col = find_col(deal_df, ["fund_id", "id"])

    # =========================
    # BASIC COUNTS
    # =========================
    total_funds = fund_df[fund_id_col].nunique() if fund_id_col else len(fund_df)

    if gp_id_col:
        total_gps = fund_df[gp_id_col].nunique(dropna=True)
        funds_per_gp = fund_df.groupby(gp_id_col)[fund_id_col].nunique() if fund_id_col else fund_df.groupby(gp_id_col).size()
        avg_funds_per_gp = funds_per_gp.mean() if not funds_per_gp.empty else np.nan
    else:
        total_gps = np.nan
        avg_funds_per_gp = np.nan

    if cf_fund_id_col:
        funds_with_cf = cf_df[cf_fund_id_col].nunique()
    else:
        funds_with_cf = np.nan

    if cap_fund_id_col and cap_nav_col:
        nav_nonmissing = cap_df[pd.to_numeric(cap_df[cap_nav_col], errors="coerce").notna()].copy()
        funds_with_nav = nav_nonmissing[cap_fund_id_col].nunique()
    else:
        nav_nonmissing = pd.DataFrame(columns=cap_df.columns)
        funds_with_nav = np.nan

    # =========================
    # FUND SIZE
    # =========================
    fund_size_stats = {"mean": np.nan, "median": np.nan, "std": np.nan, "max": np.nan}
    if fund_size_col:
        fund_size_stats = numeric_summary(fund_df[fund_size_col], digits=1)

    # =========================
    # CLEAN CASH FLOW DATA
    # =========================
    cf_clean = None
    if cf_df is not None and not cf_df.empty and cf_fund_id_col and cf_date_col:
        cf_clean = cf_df.copy()
        cf_clean[cf_date_col] = pd.to_datetime(cf_clean[cf_date_col], errors="coerce")
        cf_clean = cf_clean.dropna(subset=[cf_fund_id_col, cf_date_col])

    # =========================
    # FUND LIFE
    # =========================
    fund_life_stats = {"mean": np.nan, "median": np.nan, "min": np.nan, "max": np.nan}
    if cf_clean is not None and not cf_clean.empty and cf_type_col:
        cf_life = cf_clean.copy()
        cf_life["cf_type_lower"] = cf_life[cf_type_col].astype(str).str.lower().str.strip()
        contrib_mask = cf_life["cf_type_lower"].str.contains("contribution", na=False)
        dist_mask = cf_life["cf_type_lower"].str.contains("distribution", na=False)

        contrib_dates = cf_life.loc[contrib_mask].groupby(cf_fund_id_col)[cf_date_col].min()
        life_bounds = (
            cf_life.groupby(cf_fund_id_col)[cf_date_col]
                   .agg(["min", "max"])
        )

        funds_with_distribution = set(cf_life.loc[dist_mask, cf_fund_id_col].dropna().unique())

        life_records = []
        for fund_id, first_contrib_date in contrib_dates.items():
            if fund_id in funds_with_distribution:
                life_end_date = life_bounds.loc[fund_id, "max"]
            else:
                life_end_date = THESIS_SUBMISSION_DATE

            life_years = (life_end_date - first_contrib_date).days / 365.25
            if pd.notna(life_years) and life_years >= 0:
                life_records.append(life_years)

        if life_records:
            life_years = pd.Series(life_records, dtype=float)
            fund_life_stats = {
                "mean": life_years.mean(),
                "median": life_years.median(),
                "min": life_years.min(),
                "max": life_years.max(),
            }

    # =========================
    # VINTAGE YEAR IMPUTED FROM FIRST CONTRIBUTION DATE
    # =========================
    vintage_text = "N/A"
    if cf_clean is not None and cf_type_col:
        contrib_mask_vintage = cf_clean[cf_type_col].astype(str).str.lower().str.contains("contribution", na=False)
        contrib_df_vintage = cf_clean.loc[contrib_mask_vintage].copy()
        if not contrib_df_vintage.empty:
            first_contrib_year = contrib_df_vintage.groupby(cf_fund_id_col)[cf_date_col].min().dt.year.dropna()
            if not first_contrib_year.empty:
                vintage_text = f"{int(first_contrib_year.min())} (Earliest) – {int(first_contrib_year.max())} (Latest)"

    # =========================
    # NUM. TRANSACTIONS
    # =========================
    txn_stats = {"mean": np.nan, "median": np.nan, "min": np.nan, "max": np.nan}
    if deal_df is not None and deal_fund_id_col:
        txn_count = deal_df.groupby(deal_fund_id_col).size()
        if not txn_count.empty:
            txn_stats = {
                "mean": txn_count.mean(),
                "median": txn_count.median(),
                "min": txn_count.min(),
                "max": txn_count.max(),
            }
    elif cf_fund_id_col:
        txn_count = cf_df.groupby(cf_fund_id_col).size()
        if not txn_count.empty:
            txn_stats = {
                "mean": txn_count.mean(),
                "median": txn_count.median(),
                "min": txn_count.min(),
                "max": txn_count.max(),
            }

    # =========================
    # CURRENCY DISTRIBUTION
    # =========================
    currency_dist = "N/A"
    if currency_col:
        currency_dist = top_distribution(fund_df[currency_col], top_n=3, digits=1)

    # =========================
    # REGION DISTRIBUTION
    # =========================
    region_dist = "N/A"
    region_series = infer_region_from_country_or_currency(fund_df, country_col, currency_col)
    if region_series.notna().any():
        region_dist = top_distribution(region_series, top_n=4, digits=1)

    # =========================
    # NAV OBSERVATION COUNTS PER FUND
    # =========================
    avg_nav_obs = np.nan
    median_nav_obs = np.nan
    if cap_fund_id_col and cap_nav_col:
        cap_tmp = cap_df.copy()
        cap_tmp["_nav_numeric"] = pd.to_numeric(cap_tmp[cap_nav_col], errors="coerce")
        nav_counts = cap_tmp.loc[cap_tmp["_nav_numeric"].notna()].groupby(cap_fund_id_col).size()
        if not nav_counts.empty:
            avg_nav_obs = nav_counts.mean()
            median_nav_obs = nav_counts.median()

    # =========================
    # DISTRIBUTION COUNTS PER FUND
    # =========================
    avg_dist_obs = np.nan
    median_dist_obs = np.nan
    if cf_fund_id_col and cf_type_col:
        dist_mask = cf_df[cf_type_col].astype(str).str.lower().str.contains("distribution", na=False)
        dist_counts = cf_df.loc[dist_mask].groupby(cf_fund_id_col).size()
        if not dist_counts.empty:
            avg_dist_obs = dist_counts.mean()
            median_dist_obs = dist_counts.median()

    # =========================
    # SUMMARY TABLE
    # =========================
    summary_rows = [
        {
            "Variable": "Total Funds",
            "Unit / Description": "Count",
            "Value / Distribution": fmt_int(total_funds),
        },
        {
            "Variable": "Different GPs",
            "Unit / Description": "Count",
            "Value / Distribution": fmt_int(total_gps),
        },
        {
            "Variable": "Funds per GP",
            "Unit / Description": "Count",
            "Value / Distribution": f"Mean: {fmt_num(avg_funds_per_gp, 2)}",
        },
        *([
            {
                "Variable": "Fund Size",
                "Unit / Description": "Reported fund size",
                "Value / Distribution": (
                    f"Mean: {fmt_num(fund_size_stats['mean'],1)} / "
                    f"Median: {fmt_num(fund_size_stats['median'],1)} / "
                    f"Std: {fmt_num(fund_size_stats['std'],1)} / "
                    f"Max: {fmt_num(fund_size_stats['max'],1)}"
                ),
            }
        ] if not pd.isna(fund_size_stats['mean']) else []),
        {
            "Variable": "Funds with Cash Flow Data",
            "Unit / Description": "Count",
            "Value / Distribution": fmt_int(funds_with_cf),
        },
        {
            "Variable": "Funds with Reported NAV",
            "Unit / Description": "Count",
            "Value / Distribution": fmt_int(funds_with_nav),
        },
        {
            "Variable": "Fund Life",
            "Unit / Description": "Years (Within funds that have cash flow input)",
            "Value / Distribution": (
                f"Mean: {fmt_num(fund_life_stats['mean'],2)} / "
                f"Median: {fmt_num(fund_life_stats['median'],2)} / "
                f"Range: [{fmt_num(round(fund_life_stats['min']),0)}, {fmt_num(round(fund_life_stats['max']),0)}]"
            ),
        },
        {
            "Variable": "Num. Transactions",
            "Unit / Description": "Count per fund",
            "Value / Distribution": (
                f"Mean: {fmt_num(txn_stats['mean'],2)} / "
                f"Median: {fmt_num(txn_stats['median'],1)} / "
                f"Range: [{fmt_num(txn_stats['min'],0)}, {fmt_num(txn_stats['max'],0)}]"
            ),
        },
        {
            "Variable": "Reported NAV Observations",
            "Unit / Description": "Count per fund",
            "Value / Distribution": (
                f"Mean: {fmt_num(avg_nav_obs,2)} / "
                f"Median: {fmt_num(median_nav_obs,1)}"
            ),
        },
        {
            "Variable": "Observed Distributions",
            "Unit / Description": "Count per fund",
            "Value / Distribution": (
                f"Mean: {fmt_num(avg_dist_obs,2)} / "
                f"Median: {fmt_num(median_dist_obs,1)}"
            ),
        },
        {
            "Variable": "Currency",
            "Unit / Description": "Coverage (%)",
            "Value / Distribution": currency_dist,
        },
        {
            "Variable": "Region",
            "Unit / Description": "Coverage (%)",
            "Value / Distribution": region_dist,
        },
        {
            "Variable": "Vintage Range",
            "Unit / Description": "Years",
            "Value / Distribution": vintage_text,
        },
    ]
    summary_df = pd.DataFrame(summary_rows)

    # =========================
    # COVERAGE TABLE
    # =========================
    fund_ids_all = set(fund_df[fund_id_col].dropna().unique()) if fund_id_col else set()
    fund_ids_cf = set(cf_df[cf_fund_id_col].dropna().unique()) if cf_fund_id_col else set()
    fund_ids_nav = set(nav_nonmissing[cap_fund_id_col].dropna().unique()) if cap_fund_id_col and not nav_nonmissing.empty else set()

    funds_with_both_cf_and_nav = len(fund_ids_cf & fund_ids_nav)
    funds_with_cf_only = len(fund_ids_cf - fund_ids_nav)
    funds_with_nav_only = len(fund_ids_nav - fund_ids_cf)
    funds_with_neither = len(fund_ids_all - (fund_ids_cf | fund_ids_nav))

    total_raw_funds = len(fund_ids_all)
    funds_with_cf_data = len(fund_ids_cf)
    funds_with_nav_data = len(fund_ids_nav)

    def pct(x):
        return 100 * x / total_raw_funds if total_raw_funds else np.nan

    coverage_rows = [
        {
            "Coverage Group": "Total raw funds",
            "Count": fmt_int(total_raw_funds),
            "Share of total funds (%)": fmt_num(100, 1) if total_raw_funds else fmt_num(np.nan, 1),
        },
        {
            "Coverage Group": "Funds with cash flow data",
            "Count": fmt_int(funds_with_cf_data),
            "Share of total funds (%)": fmt_num(pct(funds_with_cf_data), 1),
        },
        {
            "Coverage Group": "Funds with reported NAV",
            "Count": fmt_int(funds_with_nav_data),
            "Share of total funds (%)": fmt_num(pct(funds_with_nav_data), 1),
        },
        {
            "Coverage Group": "Funds with both cash flow and reported NAV",
            "Count": fmt_int(funds_with_both_cf_and_nav),
            "Share of total funds (%)": fmt_num(pct(funds_with_both_cf_and_nav), 1),
        },
        {
            "Coverage Group": "Funds with cash flow only",
            "Count": fmt_int(funds_with_cf_only),
            "Share of total funds (%)": fmt_num(pct(funds_with_cf_only), 1),
        },
        {
            "Coverage Group": "Funds with reported NAV only",
            "Count": fmt_int(funds_with_nav_only),
            "Share of total funds (%)": fmt_num(pct(funds_with_nav_only), 1),
        },
        {
            "Coverage Group": "Funds with neither cash flow nor reported NAV",
            "Count": fmt_int(funds_with_neither),
            "Share of total funds (%)": fmt_num(pct(funds_with_neither), 1),
        },
    ]
    coverage_df = pd.DataFrame(coverage_rows)

    return summary_df, coverage_df


def load_clean_csv(path_str: str) -> pd.DataFrame:
    path = Path(path_str)
    if not path.exists():
        raise FileNotFoundError(f"Clean file not found: {path_str}")
    return normalize_cols(pd.read_csv(path))

# =========================
# LOAD RAW WORKBOOK
# =========================
file_path = Path(FILE_PATH)
if not file_path.exists():
    raise FileNotFoundError(f"Workbook not found: {FILE_PATH}")

xls = pd.read_excel(file_path, sheet_name=None)
xls = {k: normalize_cols(v) for k, v in xls.items()}

fund_df = find_sheet(xls, ["fund", "funds"])
cf_df = find_sheet(xls, ["fund_cash_flow", "cash_flow", "fund cash flow"])
cap_df = find_sheet(xls, ["capital_account", "fund_capital_account", "capital account"])
deal_df = find_sheet(xls, ["deal", "deals"])

if fund_df is None:
    raise ValueError("Fund sheet could not be found.")
if cf_df is None:
    raise ValueError("fund_cash_flow sheet could not be found.")
if cap_df is None:
    raise ValueError("capital_account sheet could not be found.")

raw_summary_df, raw_coverage_df = build_summary_and_coverage_tables(
    fund_df=fund_df,
    cf_df=cf_df,
    cap_df=cap_df,
    deal_df=deal_df,
)

# =========================
# LOAD FINAL / CLEAN DATA
# =========================
clean_fund_df = load_clean_csv(CLEAN_FUND_FILE)
clean_cf_df = load_clean_csv(CLEAN_CF_FILE)
clean_cap_df = load_clean_csv(CLEAN_CAP_FILE)

final_summary_df, final_coverage_df = build_summary_and_coverage_tables(
    fund_df=clean_fund_df,
    cf_df=clean_cf_df,
    cap_df=clean_cap_df,
    deal_df=None,
)

# =========================
# PRINT
# =========================
print("\nRAW DATASET SUMMARY\n")
print(raw_summary_df.to_string(index=False))
print("\nRAW DATA COVERAGE TABLE\n")
print(raw_coverage_df.to_string(index=False))

print("\nFINAL DATASET SUMMARY\n")
print(final_summary_df.to_string(index=False))
print("\nFINAL DATA COVERAGE TABLE\n")
print(final_coverage_df.to_string(index=False))

# =========================
# SAVE TO EXCEL
# =========================
with pd.ExcelWriter(OUTPUT_FILE, engine="openpyxl") as writer:
    raw_summary_df.to_excel(writer, sheet_name="Raw Dataset Summary", index=False)
    raw_coverage_df.to_excel(writer, sheet_name="Raw Data Coverage", index=False)
    final_summary_df.to_excel(writer, sheet_name="Final Dataset Summary", index=False)
    final_coverage_df.to_excel(writer, sheet_name="Final Data Coverage", index=False)

print(f"\nSummary tables saved to: {OUTPUT_FILE}")