import shutil
import pandas as pd
from pathlib import Path

# Paths (update if needed)
BASE = Path("Cleaned_Data_New")
PREBATCH_CSV = BASE / "_prebatch_outputs" / "prebatch_risk_summary.csv"
DEST = Path("multibatch_run_funds")

# Risk-free screening rule (close to the logic used in your workflow):
# - nav_obs >= 6
# - nav0_nonpos_count == 0
# - dist_obs >= 2
# You could alternatively use high_risk == 0, but the current setup follows the explicit sample-screening rule.
MIN_NAV_OBS = 6

def copy_dir(src: Path, dst: Path):
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)

def main():
    if not PREBATCH_CSV.exists():
        raise FileNotFoundError(f"Missing: {PREBATCH_CSV}")

    df = pd.read_csv(PREBATCH_CSV)

    # Expected column names in the prebatch file
    # Example fund_folder format: fund_<uuid>
    needed = {"fund_folder", "nav_obs", "nav0_nonpos_count", "dist_obs"}
    missing = needed - set(df.columns)
    if missing:
        raise ValueError(f"prebatch_risk_summary.csv missing columns: {missing}\nAvailable: {list(df.columns)}")

    # Funds that satisfy the risk-free screening rule
    good = df[(df["nav_obs"] >= MIN_NAV_OBS) & (df["nav0_nonpos_count"] == 0) & (df["dist_obs"] >= 2)].copy()

    # Excluded funds (for reference only)
    bad = df[~df.index.isin(good.index)].copy()

    # Start with a clean destination folder
    if DEST.exists():
        shutil.rmtree(DEST)
    DEST.mkdir(parents=True, exist_ok=True)

    copied = 0
    skipped = 0

    for folder in good["fund_folder"].tolist():
        src = BASE / folder
        dst = DEST / folder

        if not src.exists():
            print(f"[SKIP] missing folder in Cleaned_Data_New: {folder}")
            skipped += 1
            continue

        copy_dir(src, dst)
        copied += 1

    print("\n==== Multibatch folder prepared ====")
    print(f"Destination: {DEST.resolve()}")
    print(f"Risk-free funds copied: {copied}")
    print(f"Skipped (missing folders): {skipped}")
    print(f"Total funds in prebatch file: {len(df)}")
    print(f"Funds selected by rule (nav_obs>={MIN_NAV_OBS} & nav0_nonpos_count==0 & dist_obs>=2): {len(good)}")
    print("===================================\n")

if __name__ == "__main__":
    main()