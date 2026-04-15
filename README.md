# MasterThesis_Nowcasting_PE_NAV_Using_Proprietary_Dataset_from_GP_Reports
This link includes codes and data used in the thesis "Nowcasting Private Equity Net Asset Values Using a Proprietary Dataset Built from General Partner Reports"


**Thesis Code Package – Private Equity NAV Nowcasting**

This folder contains the main Python and MATLAB files used in my thesis project on private equity NAV nowcasting based on Brown et al. (2023), together with the core input files and one trial-fund example.

**Project purpose**
This thesis applies the PEfundSSM state-space nowcasting framework to a proprietary GP-report-based private equity dataset. The workflow has two main stages:
1. Python: data cleaning and transformation into Brown-style input files
2. MATLAB: single-fund estimation and evaluation using the state-space model

**Main files**

**1. data_cleaning.py**
This script is used to clean and standardize the raw proprietary dataset before the fund-level transformation step.

**2. data_transformation.py**
This is the main Python script used to transform the cleaned raw dataset into the fund-level CSV files required by the MATLAB model.
For each fund, it creates:
- Cs.csv
- Ds.csv
- yFund.csv
- CFandVhat.csv
- rmt.csv
- rct.csv

A Brown-style anchor-based NAV0 construction is also included in the script as a commented reference block only.
In that alternative version:
- the first week starts with the first contribution
- the naive recursion is applied forward
- whenever a reported NAV is available, NAV0 is overwritten by that reported NAV
- recursion then continues from that anchor level
Negative NAV0 values are intentionally allowed in that commented version.

**3. trial_fund_selection.py**
This script is used to identify a suitable trial fund for single-fund testing.

Current selection logic includes:
- NAV0 must remain strictly positive for all weeks
- at least 24 quarters of operation
- at least 10 reported NAV observations
- at least 2 observed distributions

These filters are intended only for trial-fund selection and not as the final batch-sample definition.

**4. market_data.py**
This script prepares the market return inputs used in data_transformation.py.

**5. dataset_summary.py**
This script is used to generate descriptive summary statistics for the proprietary dataset.
It is mainly intended to support dataset overview tables and basic checks on fund coverage, NAV availability, cash flow coverage, and related sample characteristics.

**6. prebatch_risk_summary.py**
This script is used to compute pre-estimation summary measures for funds before MATLAB batch-style testing.
Its role is to provide quick diagnostics and comparison metrics that help review the fund set before running the estimation scripts.

**7. multibatch_run_fund_folder.py**
This helper script filters the fund folders that are eligible for batch-style execution and copies them into a separate working folder.
It is used to create a dedicated set of candidate fund folders for the multibatch workflow.

**8. TrialRunner.m**
This is the main MATLAB script used to run the nowcasting model for a single trial fund.

**9. BatchTrialRunner.m**
This MATLAB script contains the batch-style trial-fund estimation logic used across multiple candidate funds instead of only one manually selected fund.
In practice, this logic is called from MultiFundRunner.m to automate repeated single-fund runs and to collect comparable estimation outputs across candidates.

**10. PEfundSSM.m**
This file contains the state-space model implementation used by the MATLAB estimation procedure.

**11. MultiFundRunner.m**
This MATLAB script was intended to run the workflow across multiple funds in a broader multi-fund setting.
It serves as the top-level runner for multi-fund execution and is the script a user would run to launch the broader multi-fund workflow.
In this package, it is included as a multi-fund runner script, but the final thesis implementation and reported results rely on the single-fund workflow rather than a completed multi-fund run.

**Input data files**

**1. CLEAN_fund.csv**
Fund-level raw input file.

**2. CLEAN_fund_cash_flow.csv**
Raw cash flow file used to construct weekly contributions and distributions.

**3. CLEAN_capital_account.csv**
Raw NAV reporting file used to extract reported NAV observations.

**4. market_data.csv**
Prepared market data file used by data_transformation.py.
It contains:
- Rm: market return series
- Rct: comparable asset return series

**Trial-fund example**
The package also includes the CSV files for the selected trial fund:
- Cs.csv
- Ds.csv
- yFund.csv
- CFandVhat.csv
- rmt.csv
- rct.csv

These files correspond to the transformed inputs used in the MATLAB single-fund run.

**Output file**

**1. EstimationSummary.xlsx**
This is the estimation output for the current trial-fund run.

**2. Figures**
Folder includes printed figures used in thesis, which visualize the results.


**How the files relate**
- data_cleaning.py prepares the cleaned proprietary input files used throughout the workflow
- market_data.py creates market_data.csv
- dataset_summary.py produces descriptive summaries of the proprietary dataset
- data_transformation.py uses the cleaned raw files and market_data.csv to build fund-level model inputs
- trial_fund_selection.py identifies the best trial fund under the current feasible selection rules
- prebatch_risk_summary.py computes pre-estimation diagnostics for reviewing candidate funds
- multibatch_run_fund_folder.py filters and copies the fund folders selected for multibatch execution
- TrialRunner.m runs the single-fund estimation
- BatchTrialRunner.m automates repeated trial-style estimation across candidate funds
- PEfundSSM.m contains the underlying state-space estimation code
- MultiFundRunner.m represents the broader multi-fund execution layer, although the final thesis results rely on the single-fund workflow
- EstimationSummary.xlsx stores the trial-fund results

**General note**
This package is intended to make it easier to review:
- how the raw proprietary dataset is cleaned and standardized
- how the dataset is summarized and screened
- how the market data inputs are prepared
- how the naive benchmark is constructed
- how the transformed inputs are created
- how the trial-fund estimation is run
- how the current results are produced
