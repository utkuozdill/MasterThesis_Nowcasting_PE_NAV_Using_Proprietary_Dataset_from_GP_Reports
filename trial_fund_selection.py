import pandas as pd
import numpy as np
import os

DATA_DIR = "dropbox_batch"
MARKET_DATA_PATH = "market_data.csv"
def _parse_date_series(series: pd.Series) -> pd.Series:
    return pd.to_datetime(series, errors="coerce")


def resolve_vintage_year_from_rmt(fund_folder: str) -> str:
    rmt_path = os.path.join(fund_folder, "rmt.csv")
    if not os.path.exists(rmt_path):
        return "Unknown"

    try:
        rmt = pd.read_csv(rmt_path, header=None).iloc[:, 0]
        rmt = pd.to_numeric(rmt, errors="coerce")
        finite_rmt = rmt[np.isfinite(rmt)]
        if finite_rmt.empty:
            return "Unknown"
        first_rmt = float(finite_rmt.iloc[0])
    except Exception:
        return "Unknown"

    if not os.path.exists(MARKET_DATA_PATH):
        return "Unknown"

    try:
        market_df = pd.read_csv(MARKET_DATA_PATH)
    except Exception:
        return "Unknown"

    if market_df.empty:
        return "Unknown"

    date_col = None
    for col in market_df.columns:
        parsed = _parse_date_series(market_df[col])
        if parsed.notna().any():
            date_col = col
            break

    if date_col is None:
        return "Unknown"

    parsed_dates = _parse_date_series(market_df[date_col])
    numeric_cols = [c for c in market_df.columns if c != date_col]

    for col in numeric_cols:
        values = pd.to_numeric(market_df[col], errors="coerce")
        match_mask = np.isclose(values, first_rmt, rtol=1e-7, atol=1e-10, equal_nan=False)
        if match_mask.any():
            matched_date = parsed_dates.loc[match_mask].dropna()
            if not matched_date.empty:
                return str(int(matched_date.iloc[0].year))

    return "Unknown"


def find_best_candidate(min_nav_reports=10):
    print("--- Searching for the best trial fund ---")

    best_fund_id = None
    best_nav_count = -1
    best_dist_count = -1
    best_total_weeks = None
    best_obs_window = None
    best_fund_folder = None

    if not os.path.exists(DATA_DIR):
        print("ERROR: dropbox_batch folder not found!")
        return

    folders = [f for f in os.listdir(DATA_DIR) if f.startswith("fund_")]
    print(f"Scanning {len(folders)} different funds...")

    for folder in folders:
        fund_id = folder.replace("fund_", "")

        # Define both yFund and CFandVhat paths
        yfund_path = os.path.join(DATA_DIR, folder, "yFund.csv")
        cf_path = os.path.join(DATA_DIR, folder, "CFandVhat.csv")
        fund_folder = os.path.join(DATA_DIR, folder)

        # Skip the fund if either file is missing
        if not os.path.exists(yfund_path) or not os.path.exists(cf_path):
            continue

        try:
            # --- Filter 1: NAV0 positivity check ---
            df_cf = pd.read_csv(cf_path, header=None, names=["Cs", "Ds", "NAV0"])

            # Skip the fund if NAV0 is zero or negative in any week
            if (df_cf["NAV0"] <= 0).any():
                continue
            # ------------------------------------------

            df = pd.read_csv(yfund_path, sep=";", header=None, names=["logDist", "logNAV"])

            # Brown-style trial-fund filters that are feasible in this dataset:
            # - at least 24 quarters of operation
            # - at least 20 quarters with reported NAVs
            # - at least 2 observed distributions
            n_weeks = len(df)
            n_quarters_operated = n_weeks / 13.0

            nav_mask = df["logNAV"].notna() & np.isfinite(df["logNAV"])
            dist_mask = df["logDist"].notna() & np.isfinite(df["logDist"])

            nav_count = int(nav_mask.sum())
            dist_count = int(dist_mask.sum())

            # Brown-style minimum history and reporting filters for trial-fund selection
            if nav_count < min_nav_reports:
                continue
            if n_quarters_operated < 24:
                continue
            if dist_count < 2:
                continue

            # Priority rule: first maximize NAV reports, then distributions in case of ties
            if (nav_count > best_nav_count) or (nav_count == best_nav_count and dist_count > best_dist_count):
                best_nav_count = nav_count
                best_dist_count = dist_count
                best_fund_id = fund_id
                best_total_weeks = int(n_weeks)
                best_obs_window = f"{int(np.ceil(n_quarters_operated))} quarters ({int(n_weeks)} weekly observations)"
                best_fund_folder = fund_folder

        except Exception as e:
            # Keep silent for now and skip malformed fund folders
            # print(f"Fund {fund_id} skipped due to error: {e}")
            continue

    print("\n" + "=" * 35)
    print("🏆 TRIAL FUND SELECTION 🏆")
    print("=" * 35)
    if best_fund_id:
        vintage_year = resolve_vintage_year_from_rmt(best_fund_folder) if best_fund_folder else "Unknown"
        print(f"Fund ID                         : {best_fund_id}")
        print(f"Total weekly observations       : {best_total_weeks}")
        print(f"Reported NAV observations       : {best_nav_count}")
        print(f"Observed distributions          : {best_dist_count}")
        print(f"Observation window              : {best_obs_window}")
        print(f"Vintage year                    : {vintage_year}")
    else:
        print("No suitable trial fund found! (Possibly all candidates failed the NAV0 > 0 filter or the Brown-style trial filters.)")
    print("=" * 35)


if __name__ == "__main__":
    find_best_candidate(min_nav_reports=10)