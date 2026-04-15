# data_transformation.py (REVISED)
import pandas as pd
import numpy as np
import os

INPUT_FUND = "CLEAN_fund.csv"
INPUT_CF = "CLEAN_fund_cash_flow.csv"
INPUT_NAV = "CLEAN_capital_account.csv"
OUTPUT_DIR = "Cleaned_Data_New"
MARKET_DATA = os.path.join(OUTPUT_DIR, "market_data.csv")

MIN_NAV_ABS = 100  # Base threshold to filter out status-code-like NAV values

def to_week_ending_friday(dt_series: pd.Series) -> pd.Series:
    # Map each date to the Friday week-ending timestamp
    return dt_series.dt.to_period("W-FRI").dt.to_timestamp(how="end").dt.normalize()

def transform_data():
    df_fund = pd.read_csv(INPUT_FUND)
    df_cf = pd.read_csv(INPUT_CF)
    df_nav = pd.read_csv(INPUT_NAV)

    df_cf["cash_flow_date"] = pd.to_datetime(df_cf["cash_flow_date"])
    df_nav["reference_date"] = pd.to_datetime(df_nav["reference_date"])

    # Market data
    if not os.path.exists(MARKET_DATA):
        raise FileNotFoundError("market_data.csv not found. Run market_data.py first.")
    mkt = pd.read_csv(MARKET_DATA)
    mkt["date"] = pd.to_datetime(mkt["date"])
    mkt = mkt.set_index("date").sort_index()
    # Rm (market) and Rct (comparable asset) expected
    if "Rm" not in mkt.columns:
        raise ValueError("Column 'Rm' is missing in market_data.csv.")
    if "Rct" not in mkt.columns:
        raise ValueError("Column 'Rct' is missing in market_data.csv. Update and run market_data.py first.")

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    processed = 0
    skipped = 0

    for fund_id in df_fund["id"].unique():
        fund_cfs = df_cf[df_cf["fund_id"] == fund_id].copy()
        fund_navs = df_nav[df_nav["fund_id"] == fund_id].copy()

        if fund_cfs.empty:
            skipped += 1
            continue


        # Split contributions and distributions
        calls = fund_cfs[fund_cfs["cash_flow_type"] == "Contribution"].copy()
        dists = fund_cfs[fund_cfs["cash_flow_type"] == "Distribution"].copy()

        if calls.empty:
            skipped += 1
            continue

        # Week-ending alignment
        calls["week_ending"] = to_week_ending_friday(calls["cash_flow_date"])
        dists["week_ending"] = to_week_ending_friday(dists["cash_flow_date"])

        # Aggregate weekly cash flows as positive amounts
        Cs = calls.groupby("week_ending")["cash_flow"].sum().abs()
        Ds = dists.groupby("week_ending")["cash_flow"].sum().abs() if not dists.empty else pd.Series(dtype=float)

        # Filter NAV observations
        nav_col = "nav_after_carried_interest_at_reported_quarter"
        if nav_col not in fund_navs.columns:
            skipped += 1
            continue

        fund_navs = fund_navs.copy()
        fund_navs[nav_col] = pd.to_numeric(fund_navs[nav_col], errors="coerce")

        # Remove status-code-like or invalid NAV values
        fund_navs = fund_navs[fund_navs[nav_col].notna()].copy()
        fund_navs = fund_navs[fund_navs[nav_col] > 0].copy()
        fund_navs = fund_navs[~fund_navs[nav_col].isin([-1, 0, 1, 2, 3])].copy()
        fund_navs = fund_navs[fund_navs[nav_col] >= MIN_NAV_ABS].copy()

        if not fund_navs.empty:
            fund_navs["week_ending"] = to_week_ending_friday(fund_navs["reference_date"])
            NAV = fund_navs.groupby("week_ending")[nav_col].last()
        else:
            NAV = pd.Series(dtype=float)

        # Timeline: start from the first contribution week
        start_date = Cs.index.min()
        # End at the latest available cash flow or NAV date
        last_date = max(
            Cs.index.max(),
            Ds.index.max() if not Ds.empty else Cs.index.max(),
            NAV.index.max() if not NAV.empty else Cs.index.max(),
        )
        end_date = last_date

        timeline = pd.date_range(start=start_date, end=end_date, freq="W-FRI")
        df_time = pd.DataFrame({"date": timeline}).set_index("date")

        # Reindex Cs, Ds, and NAV to the common weekly timeline
        Cs_full = Cs.reindex(df_time.index).fillna(0.0)
        Ds_full = Ds.reindex(df_time.index).fillna(0.0)
        NAV_full = NAV.reindex(df_time.index)  # leave missing NAV values as NaN

        # Brown-style input convention: the first row should contain a positive net contribution
        # start_date is already the first contribution week, but keep the guard explicitly
        if Cs_full.iloc[0] <= 0:
            skipped += 1
            continue

        # Market return slice on the same weekly timeline
        rmt_full = mkt["Rm"].reindex(df_time.index)
        # Brown's MATLAB code does not handle missing market returns well
        if rmt_full.isna().any():
            # This means the fund timeline extends beyond the available market data
            skipped += 1
            continue
        rmt_full = rmt_full.astype(float)

        # Comparable asset return slice (rct) on the same weekly timeline
        rct_full = mkt["Rct"].reindex(df_time.index)
        # market_data.py applies an Rct=Rm fallback before 2008, so NaNs are not expected here.
        # If anything still goes wrong, use Rct=Rm as a final fallback.
        if rct_full.isna().any():
            rct_full = rct_full.fillna(rmt_full)
        rct_full = rct_full.astype(float)

        # Alternative anchor-based NAV0 construction (kept as commented reference only)
        # The idea follows the Brown-style practitioner benchmark discussed in the paper:
        # - initialize NAV0 in the first week with the first contribution
        # - iterate forward using the naive recursion
        # - whenever a reported NAV is available in week t, overwrite NAV0[t] with the reported NAV
        # - continue the recursion from that reported NAV level until the next NAV report arrives
        # - negative NAV0 values are intentionally allowed in this version, because forcing positivity
        #   would impose additional assumptions that are not part of the raw benchmark construction
        #
        NAV0_anchor = np.zeros(len(df_time.index), dtype=float)
        NAV0_anchor[0] = float(Cs_full.iloc[0])

        for t in range(1, len(NAV0_anchor)):
            NAV0_anchor[t] = (
                NAV0_anchor[t - 1] * float(np.exp(rmt_full.iloc[t]))
                + float(Cs_full.iloc[t])
                - float(Ds_full.iloc[t])
            )

            if pd.notna(NAV_full.iloc[t]) and float(NAV_full.iloc[t]) > 0:
                NAV0_anchor[t] = float(NAV_full.iloc[t])

        # Active NAV0 construction (recursive naive nowcast): V_t = V_{t-1} * exp(rmt_t) + Cs_t - Ds_t
        #NAV0 = np.zeros(len(df_time.index), dtype=float)
        #NAV0[0] = float(Cs_full.iloc[0])  # initial NAV0 = first call of the fund
        #for t in range(1, len(NAV0)):
            #NAV0[t] = (
                #NAV0[t - 1] * float(np.exp(rmt_full.iloc[t]))
                #+ float(Cs_full.iloc[t])
                #- float(Ds_full.iloc[t])
            #)
            # In theory NAV0 is often expected to remain positive, but real data may still generate negatives.
            # We do not modify the series here; any downstream handling is left to the MATLAB side.

        # yFund: [log(Dist), log(NAV)]
        y_dist = pd.Series(np.full(len(Ds_full), np.nan), index=df_time.index)
        mask_d = Ds_full.values > 0
        y_dist.iloc[mask_d] = np.log(Ds_full.values[mask_d])
        y_nav = pd.Series(np.full(len(NAV_full), np.nan), index=df_time.index)
        mask_v = NAV_full.values > 0
        y_nav.iloc[mask_v] = np.log(NAV_full.values[mask_v])

        # Write output files
        fund_dir = os.path.join(OUTPUT_DIR, f"fund_{fund_id}")
        os.makedirs(fund_dir, exist_ok=True)

        Cs_full.to_csv(os.path.join(fund_dir, "Cs.csv"), index=False, header=False)
        Ds_full.to_csv(os.path.join(fund_dir, "Ds.csv"), index=False, header=False)

        yFund_df = pd.concat([y_dist, y_nav], axis=1)
        yFund_df.to_csv(os.path.join(fund_dir, "yFund.csv"), index=False, header=False, sep=";")

        CFandVhat = pd.DataFrame({"Cs": Cs_full.values, "Ds": Ds_full.values, "NAV0": NAV0_anchor})
        CFandVhat.to_csv(os.path.join(fund_dir, "CFandVhat.csv"), index=False, header=False)

        rmt_full.to_csv(os.path.join(fund_dir, "rmt.csv"), index=False, header=False)
        rct_full.to_csv(os.path.join(fund_dir, "rct.csv"), index=False, header=False)

        processed += 1
        if processed % 25 == 0:
            print(f"{processed} funds prepared...")

    print(f"DONE. Funds prepared: {processed}, Funds skipped: {skipped}")

if __name__ == "__main__":
    transform_data()