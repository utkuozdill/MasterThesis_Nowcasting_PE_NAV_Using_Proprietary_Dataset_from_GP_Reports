# data_cleaning.py (revised)
import pandas as pd
import os

EXCEL_FILE = "output_Studi 15 (Uktu Ö.).xlsx"

# Dictionary used to normalize raw cash flow type labels
TYPE_MAP = {
    # Contributions
    "contribution": "Contribution",
    "capital call": "Contribution",
    "capitalcall": "Contribution",
    "call": "Contribution",
    "drawdown": "Contribution",
    "paid in": "Contribution",
    "paid-in": "Contribution",
    "capital contribution": "Contribution",
    # Distributions
    "distribution": "Distribution",
    "dist": "Distribution",
    "payout": "Distribution",
    "return of capital": "Distribution",
    "proceeds": "Distribution",
}

def _require_cols(df: pd.DataFrame, cols: list[str], df_name: str):
    missing = [c for c in cols if c not in df.columns]
    if missing:
        raise KeyError(f"Missing column(s) in {df_name}: {missing}. Available columns: {df.columns.tolist()}")

def _normalize_cash_flow_type(s: pd.Series) -> pd.Series:
    x = s.astype(str).str.strip().str.lower()
    # light string cleanup before mapping
    x = x.str.replace(r"\s+", " ", regex=True)
    x = x.str.replace("_", " ")
    return x.map(TYPE_MAP)

def main():
    if not os.path.exists(EXCEL_FILE):
        raise FileNotFoundError(f"Excel file not found: {EXCEL_FILE}")

    xls = pd.ExcelFile(EXCEL_FILE)

    # --- Load sheets ---
    df_fund = pd.read_excel(xls, sheet_name="fund")
    df_cf = pd.read_excel(xls, sheet_name="fund_cash_flow")
    df_nav = pd.read_excel(xls, sheet_name="capital_account")

    # --- Required column checks ---
    _require_cols(df_fund, ["id"], "fund")
    _require_cols(df_cf, ["fund_id", "cash_flow_date", "cash_flow", "cash_flow_type"], "fund_cash_flow")
    _require_cols(df_nav, ["fund_id", "reference_date"], "capital_account")

    # --- Parse dates ---
    df_cf["cash_flow_date"] = pd.to_datetime(df_cf["cash_flow_date"], errors="coerce")
    df_nav["reference_date"] = pd.to_datetime(df_nav["reference_date"], errors="coerce")

    # Drop rows with missing critical fields
    df_cf = df_cf[df_cf["fund_id"].notna()].copy()
    df_cf = df_cf[df_cf["cash_flow_date"].notna()].copy()

    # Convert cash_flow to numeric
    df_cf["cash_flow"] = pd.to_numeric(df_cf["cash_flow"], errors="coerce")
    df_cf = df_cf[df_cf["cash_flow"].notna()].copy()

    # --- Normalize cash flow type and keep only Contribution / Distribution ---
    df_cf["cash_flow_type"] = _normalize_cash_flow_type(df_cf["cash_flow_type"])

    before = len(df_cf)
    df_cf = df_cf[df_cf["cash_flow_type"].isin(["Contribution", "Distribution"])].copy()
    after = len(df_cf)

    # --- Remove ghost funds: keep only funds with at least one observed Contribution ---
    contrib_funds = (
        df_cf[df_cf["cash_flow_type"] == "Contribution"]
        .groupby("fund_id")["cash_flow_date"]
        .min()
    )
    valid_fund_ids = contrib_funds.index.unique()

    df_fund_clean = df_fund[df_fund["id"].isin(valid_fund_ids)].copy()
    df_cf_clean = df_cf[df_cf["fund_id"].isin(valid_fund_ids)].copy()
    df_nav_clean = df_nav[df_nav["fund_id"].isin(valid_fund_ids)].copy()

    # --- Vintage year overwrite using first contribution year ---
    # The raw vintage_year field is highly unreliable in this dataset, so we replace it
    # for all surviving funds with the year of the first observed contribution.
    implied_vintage = contrib_funds.dt.year.rename("implied_vintage")
    df_fund_clean = df_fund_clean.merge(implied_vintage, left_on="id", right_index=True, how="left")

    # Keep only funds for which a first contribution year exists.
    df_fund_clean = df_fund_clean[df_fund_clean["implied_vintage"].notna()].copy()
    df_fund_clean["vintage_year"] = df_fund_clean["implied_vintage"].astype(int)

    # Re-align the other cleaned tables after the final fund-level filter.
    valid_fund_ids2 = df_fund_clean["id"].unique()
    df_cf_clean = df_cf_clean[df_cf_clean["fund_id"].isin(valid_fund_ids2)].copy()
    df_nav_clean = df_nav_clean[df_nav_clean["fund_id"].isin(valid_fund_ids2)].copy()
    df_fund_clean = df_fund_clean.drop(columns=["implied_vintage"], errors="ignore")

    # --- Final sanity checks ---
    if "cash_flow_type" not in df_cf_clean.columns:
        raise RuntimeError("ERROR: cash_flow_type disappeared from CLEAN_fund_cash_flow.csv. This should not happen.")

    # --- Save cleaned outputs ---
    df_fund_clean.to_csv("CLEAN_fund.csv", index=False)
    df_cf_clean.to_csv("CLEAN_fund_cash_flow.csv", index=False)
    df_nav_clean.to_csv("CLEAN_capital_account.csv", index=False)

    print("Cleaning completed.")
    print(f"  - Clean fund count: {df_fund_clean['id'].nunique()}")
    print(f"  - Cash flow rows kept after type filter: {after} / {before}")
    print("  - CLEAN_fund.csv")
    print("  - CLEAN_fund_cash_flow.csv (cash_flow_type retained)")
    print("  - CLEAN_capital_account.csv")

if __name__ == "__main__":
    main()