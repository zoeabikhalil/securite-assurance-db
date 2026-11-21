# Sécurité Assurance – Motor Policy and Claims Management Database
INDE 513 Information Systems · Final project (Phase II) · Fall 2026
Team: Ella Abi Farah, Jane Salemeh, Lynn Kabban, Sheryl El Hajj, Zoe Abi Khalil

Website link: [add the Render URL here once deployed]

## Contents
| Folder | What is inside |
|---|---|
| `sql/` | `01_schema.sql` (13 tables, constraints, triggers, views), `02_data.sql` (fictional sample data), `03_queries.sql` (13 queries), `04_constraint_tests.sql` (statements the database must reject) |
| `website/` | Flask website connected to the SQLite database |
| `diagrams/` | diagrams.net files: ER diagrams (Phase I) and relational schema / FD diagrams (Phase II). Open at https://app.diagrams.net |

## 1. Run the SQL (SQLite)
```bash
cd sql
sqlite3 securite.db < 01_schema.sql
sqlite3 securite.db < 02_data.sql
sqlite3 securite.db < 03_queries.sql
```
Each script starts with `PRAGMA foreign_keys = ON;`. Run the statements in `04_constraint_tests.sql` one at a time: every one of them should fail.
The scripts also work in DB Browser for SQLite (Execute SQL tab).

## 2. Run the website locally
Requires Python 3.10+.
```bash
cd website
pip install -r requirements.txt
python app.py
```
Open http://127.0.0.1:5000. On first start the app builds `securite.db` from `website/sql/`. Delete `securite.db` to reset the data.

Pages: Dashboard · Policies (search, detail, record a payment) · Customers (search, add) · Claims (filter, detail, report a new claim) · SQL reports (runs the 13 queries live).

## 3. Put the website online (Render, free plan)
1. Create a GitHub repository and upload the **contents of the `website/` folder** (app.py, requirements.txt, render.yaml, templates/, static/, sql/).
2. On https://render.com sign in with GitHub → **New → Blueprint** → choose the repository. Render reads `render.yaml` (build: `pip install -r requirements.txt`, start: `gunicorn app:app`).
   Alternatively **New → Web Service** with those two commands and Python 3.
3. Wait for the deploy to finish and copy the `https://….onrender.com` link into this README and the report.

Note: on the free plan the service sleeps when idle (first load takes ~1 minute) and the database is rebuilt from the SQL scripts on each restart, so records added during a demo are not permanent.

## Data
All customer, vehicle and claim records are fictional. Only the business rules come from Sécurité Assurance.
