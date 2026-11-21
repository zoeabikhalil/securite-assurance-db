"""Sécurité Assurance – Motor Policy & Claims database (INDE 513 project website).

Run locally:   pip install -r requirements.txt  then  python app.py   (http://127.0.0.1:5000)
On Render:     gunicorn app:app   (see render.yaml)
The SQLite file is built automatically from sql/01_schema.sql and sql/02_data.sql the first time.
"""
import os
import re
import sqlite3
from datetime import date

from flask import Flask, abort, flash, g, redirect, render_template, request, send_from_directory, url_for

BASE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.environ.get("DATABASE_PATH", os.path.join(BASE, "securite.db"))


def _sub(name):
    """Use the sub-folder if it exists; otherwise expect the files next to app.py (flat upload)."""
    p = os.path.join(BASE, name)
    return p if os.path.isdir(p) else BASE


SQL_DIR = _sub("sql")
STATIC_DIR = _sub("static")

app = Flask(__name__, template_folder=_sub("templates"), static_folder=None)


@app.route("/static/<path:filename>")
def static(filename):
    if not filename.endswith(".css"):
        abort(404)
    return send_from_directory(STATIC_DIR, filename)
app.secret_key = os.environ.get("SECRET_KEY", "inde513-dev-key")


# ---------------------------------------------------------------- database
def build_database():
    con = sqlite3.connect(DB_PATH)
    con.execute("PRAGMA foreign_keys = ON")
    for f in ("01_schema.sql", "02_data.sql"):
        with open(os.path.join(SQL_DIR, f), encoding="utf-8") as fh:
            con.executescript(fh.read())
    con.commit()
    con.close()


def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA foreign_keys = ON")  # enforced on every connection
    return g.db


@app.teardown_appcontext
def close_db(_exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def q(sql, args=(), one=False):
    cur = get_db().execute(sql, args)
    rows = cur.fetchall()
    return (rows[0] if rows else None) if one else rows


if not os.path.exists(DB_PATH):
    build_database()


@app.template_filter("money")
def money(v):
    return "–" if v is None else f"{float(v):,.2f}"


# ---------------------------------------------------------------- pages
@app.route("/")
def dashboard():
    today = date.today().isoformat()
    kpi = {
        "active": q("SELECT COUNT(*) n FROM POLICY WHERE Status='Active'", one=True)["n"],
        "customers": q("SELECT COUNT(*) n FROM CUSTOMER", one=True)["n"],
        "open_claims": q("SELECT COUNT(*) n FROM CLAIM WHERE ClaimStatus IN ('Reported','Under Review','Approved')", one=True)["n"],
        "overdue": q("""SELECT COALESCE(SUM(AmountDue-AmountPaid),0) n FROM PAYMENT
                        WHERE DueDate < ? AND PaymentStatus IN ('Pending','Partial')""", (today,), one=True)["n"],
    }
    overdue = q("""
        SELECT p.PolicyID, p.PolicyNumber, c.FullName, COUNT(*) AS Instalments,
               ROUND(SUM(pay.AmountDue - pay.AmountPaid), 2) AS Outstanding, MIN(pay.DueDate) AS Oldest
        FROM PAYMENT pay JOIN POLICY p ON p.PolicyID = pay.PolicyID
        JOIN CUSTOMER c ON c.CustomerID = p.CustomerID
        WHERE pay.DueDate < ? AND pay.PaymentStatus IN ('Pending','Partial')
        GROUP BY p.PolicyID HAVING SUM(pay.AmountDue - pay.AmountPaid) > 0
        ORDER BY Outstanding DESC""", (today,))
    open_claims = q("""
        SELECT cl.ClaimID, cl.ClaimReference, cl.ClaimStatus, cl.ReportedDate, p.PolicyNumber, c.FullName,
               CAST(julianday('now') - julianday(cl.ReportedDate) AS INTEGER) AS DaysOpen
        FROM CLAIM cl JOIN POLICY p ON p.PolicyID = cl.PolicyID JOIN CUSTOMER c ON c.CustomerID = p.CustomerID
        WHERE cl.ClaimStatus IN ('Reported','Under Review','Approved')
        ORDER BY DaysOpen DESC""")
    return render_template("dashboard.html", kpi=kpi, overdue=overdue, open_claims=open_claims, today=today)


@app.route("/policies")
def policies():
    term = request.args.get("q", "").strip()
    status = request.args.get("status", "")
    sql = """SELECT p.PolicyID, p.PolicyNumber, p.Status, p.StartDate, p.EndDate, p.PremiumAmount, p.Currency,
                    c.FullName, m.Make, v.ModelName, v.PlateNumber
             FROM POLICY p JOIN CUSTOMER c ON c.CustomerID = p.CustomerID
             JOIN VEHICLE v ON v.VehicleID = p.VehicleID JOIN VEHICLE_MODEL m ON m.ModelName = v.ModelName
             WHERE (p.PolicyNumber LIKE ? OR c.FullName LIKE ? OR v.PlateNumber LIKE ?)"""
    like = f"%{term}%"
    args = [like, like, like]
    if status:
        sql += " AND p.Status = ?"
        args.append(status)
    sql += " ORDER BY p.PolicyNumber"
    return render_template("policies.html", rows=q(sql, args), term=term, status=status)


@app.route("/policies/<int:pid>")
def policy_detail(pid):
    pol = q("SELECT * FROM v_policy_overview WHERE PolicyID = ?", (pid,), one=True)
    if pol is None:
        flash("Policy not found.", "error")
        return redirect(url_for("policies"))
    covers = q("""SELECT o.OptionCode, o.OptionName, pc.SelectedLimit, pc.Deductible, pc.CoverPremium
                  FROM POLICY_COVERAGE pc JOIN COVERAGE_OPTION o ON o.OptionID = pc.OptionID
                  WHERE pc.PolicyID = ? ORDER BY o.OptionID""", (pid,))
    pays = q("SELECT * FROM v_payment_balance WHERE PolicyID = ? ORDER BY InstallmentNo", (pid,))
    claims = q("SELECT * FROM v_claim_overview WHERE PolicyID = ? ORDER BY ReportedDate DESC", (pid,))
    return render_template("policy_detail.html", p=pol, covers=covers, pays=pays, claims=claims)


@app.route("/payments/<int:pay_id>/pay", methods=["POST"])
def record_payment(pay_id):
    pay = q("SELECT * FROM PAYMENT WHERE PaymentID = ?", (pay_id,), one=True)
    if pay is None:
        flash("Instalment not found.", "error")
        return redirect(url_for("policies"))
    try:
        amount = round(float(request.form.get("amount", "0")), 2)
    except ValueError:
        amount = 0
    if amount <= 0:
        flash("Enter a positive amount.", "error")
        return redirect(url_for("policy_detail", pid=pay["PolicyID"]))
    new_paid = round(pay["AmountPaid"] + amount, 2)
    status = "Paid" if new_paid >= pay["AmountDue"] else "Partial"
    try:
        db = get_db()
        db.execute("UPDATE PAYMENT SET AmountPaid = ?, PaidDate = ?, PaymentStatus = ? WHERE PaymentID = ?",
                   (new_paid, date.today().isoformat(), status, pay_id))
        db.commit()
        flash(f"Payment of {amount:,.2f} recorded on instalment {pay['InstallmentNo']}.", "ok")
    except sqlite3.IntegrityError as e:
        flash(f"Rejected by the database: {e}", "error")
    return redirect(url_for("policy_detail", pid=pay["PolicyID"]))


@app.route("/customers")
def customers():
    term = request.args.get("q", "").strip()
    like = f"%{term}%"
    rows = q("""SELECT c.CustomerID, c.CustomerNumber, c.FullName, c.CityName, ci.District, c.Email,
                       GROUP_CONCAT(DISTINCT ph.PhoneNumber) AS Phones,
                       (SELECT COUNT(*) FROM POLICY p WHERE p.CustomerID = c.CustomerID) AS Policies
                FROM CUSTOMER c JOIN CITY ci ON ci.CityName = c.CityName
                LEFT JOIN CUSTOMER_PHONE ph ON ph.CustomerID = c.CustomerID
                WHERE c.FullName LIKE ? OR c.CustomerNumber LIKE ? OR ph.PhoneNumber LIKE ?
                GROUP BY c.CustomerID ORDER BY c.FullName""", (like, like, like))
    return render_template("customers.html", rows=rows, term=term)


@app.route("/customers/<int:cid>")
def customer_detail(cid):
    c = q("""SELECT c.*, ci.District, CAST((julianday('now') - julianday(c.DateOfBirth)) / 365.25 AS INTEGER) AS Age
             FROM CUSTOMER c JOIN CITY ci ON ci.CityName = c.CityName WHERE c.CustomerID = ?""", (cid,), one=True)
    if c is None:
        flash("Customer not found.", "error")
        return redirect(url_for("customers"))
    phones = q("SELECT PhoneNumber FROM CUSTOMER_PHONE WHERE CustomerID = ?", (cid,))
    pols = q("SELECT * FROM v_policy_overview WHERE CustomerID = ? ORDER BY PolicyNumber", (cid,))
    return render_template("customer_detail.html", c=c, phones=phones, pols=pols)


@app.route("/customers/new", methods=["GET", "POST"])
def customer_new():
    cities = q("SELECT CityName, District FROM CITY ORDER BY CityName")
    form = request.form
    if request.method == "POST":
        phones = [p.strip() for p in re.split(r"[,\n]", form.get("phones", "")) if p.strip()]
        if not phones:
            flash("At least one phone number is required.", "error")
            return render_template("customer_new.html", cities=cities, form=form)
        db = get_db()
        nxt = q("SELECT COALESCE(MAX(CustomerID), 100) + 1 AS n FROM CUSTOMER", one=True)["n"]
        number = f"CU{100 + nxt:06d}"
        try:
            cur = db.execute("""INSERT INTO CUSTOMER (CustomerNumber, FullName, DateOfBirth, Email, Street, CityName)
                                VALUES (?, ?, ?, ?, ?, ?)""",
                             (number, form["full_name"].strip(), form["dob"], form.get("email").strip() or None,
                              form["street"].strip(), form["city"]))
            for ph in phones:
                db.execute("INSERT INTO CUSTOMER_PHONE (CustomerID, PhoneNumber) VALUES (?, ?)", (cur.lastrowid, ph))
            db.commit()
            flash(f"Customer {number} added.", "ok")
            return redirect(url_for("customer_detail", cid=cur.lastrowid))
        except sqlite3.IntegrityError as e:
            db.rollback()
            flash(f"Rejected by the database: {e}", "error")
    return render_template("customer_new.html", cities=cities, form=form)


@app.route("/claims")
def claims():
    status = request.args.get("status", "")
    sql = """SELECT cl.*, p.PolicyNumber, c.FullName FROM v_claim_overview cl
             JOIN POLICY p ON p.PolicyID = cl.PolicyID JOIN CUSTOMER c ON c.CustomerID = p.CustomerID"""
    args = []
    if status:
        sql += " WHERE cl.ClaimStatus = ?"
        args.append(status)
    sql += " ORDER BY cl.ReportedDate DESC"
    return render_template("claims.html", rows=q(sql, args), status=status)


@app.route("/claims/<int:cid>")
def claim_detail(cid):
    cl = q("""SELECT cl.*, p.PolicyNumber, p.PolicyID, c.FullName, v.PlateNumber
              FROM v_claim_overview cl JOIN POLICY p ON p.PolicyID = cl.PolicyID
              JOIN CUSTOMER c ON c.CustomerID = p.CustomerID JOIN VEHICLE v ON v.VehicleID = p.VehicleID
              WHERE cl.ClaimID = ?""", (cid,), one=True)
    if cl is None:
        flash("Claim not found.", "error")
        return redirect(url_for("claims"))
    parts = q("SELECT PartName FROM CLAIM_DAMAGED_PART WHERE ClaimID = ? ORDER BY PartName", (cid,))
    docs = q("SELECT * FROM CLAIM_DOCUMENT WHERE ClaimID = ? ORDER BY DocumentNo", (cid,))
    asm = q("SELECT * FROM CLAIM_ASSESSMENT WHERE ClaimID = ?", (cid,), one=True)
    return render_template("claim_detail.html", cl=cl, parts=parts, docs=docs, asm=asm)


PARTS = ["Front Bumper", "Rear Bumper", "Hood", "Headlight", "Tail Light", "Front Door", "Rear Door",
         "Side Mirror", "Windscreen", "Side Window", "Wheel Rim", "Suspension", "Engine", "Interior"]


@app.route("/claims/new", methods=["GET", "POST"])
def claim_new():
    pols = q("""SELECT p.PolicyID, p.PolicyNumber, c.FullName, v.PlateNumber, p.StartDate, p.EndDate
                FROM POLICY p JOIN CUSTOMER c ON c.CustomerID = p.CustomerID JOIN VEHICLE v ON v.VehicleID = p.VehicleID
                WHERE p.Status = 'Active' ORDER BY p.PolicyNumber""")
    form = request.form
    if request.method == "POST":
        parts = form.getlist("parts")
        if not parts:
            flash("Select at least one damaged part.", "error")
            return render_template("claim_new.html", pols=pols, parts=PARTS, form=form, today=date.today().isoformat())
        db = get_db()
        year = form["reported"][:4]
        n = q("SELECT COUNT(*) + 1 AS n FROM CLAIM WHERE ClaimReference LIKE ?", (f"CLM-{year}-%",), one=True)["n"]
        n = max(n, q("SELECT COALESCE(MAX(ClaimID),0)+1 AS n FROM CLAIM", one=True)["n"])
        ref = f"CLM-{year}-{n:03d}"
        amount = form.get("amount", "").strip()
        try:
            cur = db.execute("""INSERT INTO CLAIM (ClaimReference, PolicyID, IncidentDate, ReportedDate, Description, ClaimedAmount)
                                VALUES (?, ?, ?, ?, ?, ?)""",
                             (ref, int(form["policy"]), form["incident"], form["reported"], form["description"].strip(),
                              float(amount) if amount else None))
            for p in parts:
                db.execute("INSERT INTO CLAIM_DAMAGED_PART (ClaimID, PartName) VALUES (?, ?)", (cur.lastrowid, p))
            db.commit()
            flash(f"Claim {ref} registered.", "ok")
            return redirect(url_for("claim_detail", cid=cur.lastrowid))
        except (sqlite3.IntegrityError, ValueError) as e:
            db.rollback()
            flash(f"Rejected by the database: {e}", "error")
    return render_template("claim_new.html", pols=pols, parts=PARTS, form=form, today=date.today().isoformat())


def load_queries():
    with open(os.path.join(SQL_DIR, "03_queries.sql"), encoding="utf-8") as fh:
        txt = fh.read()
    out = []
    for b in re.split(r"\n(?=-- Q\d+ \|)", txt)[1:]:
        lines = b.strip().split("\n")
        out.append(dict(title=lines[0][3:],
                        question=" ".join(l[3:] for l in lines[1:] if l.startswith("--")),
                        sql="\n".join(l for l in lines if not l.startswith("--")).strip()))
    return out


@app.route("/reports")
def reports():
    qs = load_queries()
    sel = request.args.get("q", type=int, default=4)
    sel = min(max(sel, 1), len(qs))
    cur = get_db().execute(qs[sel - 1]["sql"])
    cols = [d[0] for d in cur.description]
    return render_template("reports.html", qs=qs, sel=sel, cur=qs[sel - 1], cols=cols, rows=cur.fetchall())


if __name__ == "__main__":
    app.run(debug=True)
