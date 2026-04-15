import pandas as pd
import numpy as np
from pathlib import Path
from collections import Counter

# -----------------------------
# CONFIG
# -----------------------------
BASE_DIR = Path("Cleaned_Data_New")
OUTPUT_DIR = BASE_DIR / "_prebatch_outputs"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# Thresholds (risk icin kullanilanlar)
MAX_RMT_ABS = 0.30  # weekly log return extreme threshold

# Some files in your pipeline used semicolon delimiter for yFund
YFUND_DELIMS_TO_TRY = [";", ","]


def read_yfund(path: Path) -> pd.DataFrame:
    # Try ; then ,
    for sep in YFUND_DELIMS_TO_TRY:
        try:
            df = pd.read_csv(path, sep=sep, header=None)
            if df.shape[1] >= 2:
                return df.iloc[:, :2]
        except Exception:
            pass
    # Last attempt: default
    df = pd.read_csv(path, header=None)
    return df.iloc[:, :2] if df.shape[1] >= 2 else df


def read_vector(path: Path) -> pd.Series:
    df = pd.read_csv(path, header=None)
    if df.shape[1] >= 1:
        return pd.to_numeric(df.iloc[:, 0], errors="coerce")
    return pd.Series(dtype=float)


def read_cfandvhat(path: Path) -> pd.DataFrame:
    return pd.read_csv(path, header=None)


def first_non_nan_index(s: pd.Series):
    idx = s.first_valid_index()
    if idx is None:
        return None
    return int(idx)


def main():
    if not BASE_DIR.exists():
        raise FileNotFoundError(f"Base dir not found: {BASE_DIR.resolve()}")

    # fund folder = directory that contains yFund.csv and Cs.csv
    fund_dirs = []
    for p in BASE_DIR.iterdir():
        if p.is_dir() and not p.name.startswith("_"):
            if (p / "yFund.csv").exists() and (p / "Cs.csv").exists():
                fund_dirs.append(p)
    fund_dirs = sorted(fund_dirs)

    if len(fund_dirs) == 0:
        raise RuntimeError(
            f"No fund folders found under {BASE_DIR.resolve()}. "
            "Expected subfolders that contain yFund.csv and Cs.csv."
        )

    rows = []
    reasons_counter = Counter()

    for fd in fund_dirs:
        fund_folder = fd.name

        y_path = fd / "yFund.csv"
        rmt_path = fd / "rmt.csv"
        cv_path = fd / "CFandVhat.csv"

        y = read_yfund(y_path)
        rmt = read_vector(rmt_path)
        cv = read_cfandvhat(cv_path)

        # yFund stats
        if y.shape[1] < 2:
            log_dist = pd.Series([np.nan] * len(y))
            log_nav = pd.Series([np.nan] * len(y))
        else:
            log_dist = pd.to_numeric(y.iloc[:, 0], errors="coerce")
            log_nav = pd.to_numeric(y.iloc[:, 1], errors="coerce")

        T = len(y)
        dist_obs = int(log_dist.notna().sum())
        nav_obs = int(log_nav.notna().sum())

        dist_first = first_non_nan_index(log_dist)
        nav_first = first_non_nan_index(log_nav)

        allnan_rows = int(((log_dist.isna()) & (log_nav.isna())).sum())
        allnan_share = (allnan_rows / T) if T > 0 else np.nan

        # rmt stats
        rmt_nan = int(rmt.isna().sum())
        rmt_abs_max = float(np.nanmax(np.abs(rmt.values))) if len(rmt) > 0 else np.nan
        rmt_extreme_cnt = int((np.abs(rmt) > MAX_RMT_ABS).sum())

        # NAV0 stats: third column in CFandVhat
        nav0_min = np.nan
        nav0_nonpos_cnt = 0
        if cv.shape[1] >= 3:
            nav0 = pd.to_numeric(cv.iloc[:, 2], errors="coerce")
            nav0_clean = nav0.dropna()
            if len(nav0_clean) > 0:
                nav0_min = float(nav0_clean.min())
                nav0_nonpos_cnt = int((nav0_clean <= 0).sum())

        # High risk flags
        reasons = []

        # Distribution observation scarcity is meaningful
        if dist_obs == 0:
            reasons.append("no_dist_obs")
        elif dist_obs < 2:
            reasons.append("not_enough_dist_obs<2")
        # NAV observation scarcity is meaningful
        if nav_obs == 0:
            reasons.append("no_nav_obs")
        elif nav_obs < 6:
            reasons.append("very_low_nav_obs<6")

        # NAV0 positivity is meaningful
        if nav0_nonpos_cnt > 0:
            reasons.append("nav0_nonpositive")

        # rmt quality is meaningful
        if rmt_nan > 0:
            reasons.append("rmt_has_nan")
        if rmt_extreme_cnt > 0:
            reasons.append(f"rmt_extreme_abs>{MAX_RMT_ABS}")

        is_high_risk = (len(reasons) > 0)
        for r in reasons:
            reasons_counter[r] += 1

        rows.append({
            "fund_folder": fund_folder,
            "T_weeks": T,
            "dist_obs": dist_obs,
            "nav_obs": nav_obs,
            "dist_first_idx": dist_first if dist_first is not None else "",
            "nav_first_idx": nav_first if nav_first is not None else "",
            "allnan_rows": allnan_rows,
            "allnan_share": round(allnan_share, 4) if pd.notna(allnan_share) else "",
            "rmt_nan_count": rmt_nan,
            "rmt_abs_max": round(rmt_abs_max, 6) if pd.notna(rmt_abs_max) else "",
            "rmt_extreme_count": rmt_extreme_cnt,
            "nav0_min": round(nav0_min, 6) if pd.notna(nav0_min) else "",
            "nav0_nonpos_count": nav0_nonpos_cnt,
            "high_risk": int(is_high_risk),
            "risk_reasons": "|".join(reasons)
        })

    report = pd.DataFrame(rows).sort_values(["high_risk", "fund_folder"], ascending=[False, True])

    report_path = OUTPUT_DIR / "prebatch_risk_summary.csv"
    report.to_csv(report_path, index=False)

    high_risk_df = report.loc[report["high_risk"] == 1].copy()
    high_risk_path = OUTPUT_DIR / "prebatch_high_risk_funds.csv"
    high_risk_df.to_csv(high_risk_path, index=False)

    total = len(report)
    n_high = int((report["high_risk"] == 1).sum())
    n_low = total - n_high

    print("\n========== Pre-batch Risk Summary ==========")
    print(f"Base dir: {BASE_DIR.resolve()}")
    print(f"Funds checked: {total}")
    print(f"High risk: {n_high}")
    print(f"Low risk:  {n_low}")

    if reasons_counter:
        print("\nTop risk reasons:")
        for k, v in reasons_counter.most_common(10):
            print(f"- {k}: {v}")
    else:
        print("\nNo risk reasons triggered with current thresholds.")

    # NAV obs buckets
    nav0 = int((report["nav_obs"] == 0).sum())
    nav12 = int(((report["nav_obs"] >= 1) & (report["nav_obs"] <= 2)).sum())
    nav34 = int(((report["nav_obs"] >= 3) & (report["nav_obs"] <= 4)).sum())
    nav5p = int((report["nav_obs"] >= 5).sum())

    print("\nNAV observation buckets:")
    print(f"- nav_obs = 0   : {nav0}")
    print(f"- nav_obs = 1-2 : {nav12}")
    print(f"- nav_obs = 3-4 : {nav34}")
    print(f"- nav_obs >= 5  : {nav5p}")

    print("\nOutputs:")
    print(f"- {report_path.resolve()}")
    print(f"- {high_risk_path.resolve()}")
    print("===========================================\n")


if __name__ == "__main__":
    main()