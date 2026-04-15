import yfinance as yf
import pandas as pd
import numpy as np
import os

# --- SETTINGS ---
OUTPUT_DIR = "Cleaned_Data_New"
START_DATE = "1980-01-01"
END_DATE = "2026-01-01"


def _flatten_columns(df: pd.DataFrame) -> pd.DataFrame:
    # yfinance sometimes returns a MultiIndex, so we flatten it to a single level
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    return df


def _pick_price(df: pd.DataFrame, label: str) -> pd.Series:
    if "Adj Close" in df.columns:
        return df["Adj Close"]
    if "Close" in df.columns:
        print(f"Warning: 'Adj Close' not found for {label}; using 'Close' instead.")
        return df["Close"]
    print(f"Warning: price column not found for {label}; using the first column.")
    return df.iloc[:, 0]


def get_market_data():
    print("--- Downloading market data (rmt=S&P 500, rct=MSCI ACWI ETF)... ---")

    # rmt: S&P 500
    sp500 = yf.download("^GSPC", start=START_DATE, end=END_DATE, progress=False, auto_adjust=False)
    if sp500.empty:
        print("ERROR: ^GSPC could not be downloaded. Check your internet connection or Yahoo Finance access.")
        return

    # rct: Comparable asset proxy (global): iShares MSCI ACWI ETF
    acwi = yf.download("ACWI", start=START_DATE, end=END_DATE, progress=False, auto_adjust=False)
    if acwi.empty:
        print("ERROR: ACWI could not be downloaded. Check the Yahoo Finance ticker or access.")
        return

    sp500 = _flatten_columns(sp500)
    acwi = _flatten_columns(acwi)

    rmt_prices = _pick_price(sp500, "S&P 500 (^GSPC)")
    rct_prices = _pick_price(acwi, "ACWI")

    print("Converting to weekly (Friday) frequency...")

    rmt_weekly = rmt_prices.resample("W-FRI").last()
    rct_weekly = rct_prices.resample("W-FRI").last()

    # Date range issue: ACWI starts in 2008, while the S&P 500 begins earlier.
    # Therefore, we take the union instead of the intersection (rather than dropna with how='any').
    weekly = pd.DataFrame(
        {
            "Price_rmt": rmt_weekly,
            "Price_rct": rct_weekly,
        }
    )

    # Log returns
    market_returns = pd.DataFrame(index=weekly.index)
    market_returns["Price_rmt"] = weekly["Price_rmt"]
    market_returns["Price_rct"] = weekly["Price_rct"]

    market_returns["Rm"] = np.log(weekly["Price_rmt"] / weekly["Price_rmt"].shift(1))
    market_returns["Rct"] = np.log(weekly["Price_rct"] / weekly["Price_rct"].shift(1))

    # For Rm: the first row becomes NaN, so set it to 0
    market_returns["Rm"] = market_returns["Rm"].fillna(0)

    # For Rct: values are NaN in periods before ACWI starts.
    # In those periods, use Rct = Rm as a fallback (the repcode already sets rct = rmt when rct is unavailable).
    market_returns["Rct"] = market_returns["Rct"].fillna(market_returns["Rm"])

    # Price columns are included for reference only. Forward-fill missing values (this does not affect return calculations).
    market_returns["Price_rmt"] = market_returns["Price_rmt"].ffill()
    market_returns["Price_rct"] = market_returns["Price_rct"].ffill()

    market_returns.reset_index(inplace=True)
    market_returns.rename(columns={"Date": "date"}, inplace=True)

    if not os.path.exists(OUTPUT_DIR):
        os.makedirs(OUTPUT_DIR)

    output_path = os.path.join(OUTPUT_DIR, "market_data.csv")
    market_returns.to_csv(output_path, index=False)

    print(f"\nSUCCESS! Market data ready (Rm + Rct): {output_path}")
    print(f"Date Range: {market_returns['date'].min()} - {market_returns['date'].max()}")
    print("Columns:", list(market_returns.columns))


if __name__ == "__main__":
    get_market_data()