
from sqlalchemy import text

from database import Base, engine, SessionLocal
import models

ALTER_STATEMENTS = [
    "ALTER TABLE employees ADD COLUMN IF NOT EXISTS email VARCHAR",
    "ALTER TABLE employees ADD COLUMN IF NOT EXISTS is_hr BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE change_history ADD COLUMN IF NOT EXISTS reason VARCHAR",
    "CREATE UNIQUE INDEX IF NOT EXISTS ix_employees_email ON employees (email)",
]

SEED_EMPLOYEES = [
    {
        "email": "chulsoo.kim@company.com",
        "name": "김철수",
        "department": "개발팀",
        "position": "대리",
        "salary": 52000000,
        "is_hr": False,
    },
    {
        "email": "younghee.lee@company.com",
        "name": "이영희",
        "department": "영업팀",
        "position": "과장",
        "salary": 61000000,
        "is_hr": False,
    },
    {
        "email": "gildong.hong@company.com",
        "name": "홍길동",
        "department": "기획팀",
        "position": "사원",
        "salary": 45000000,
        "is_hr": False,
    },
    {
        "email": "minsu.park@company.com",
        "name": "박민수",
        "department": "인사팀",
        "position": "인사팀장",
        "salary": 70000000,
        "is_hr": True,
    },
]

if __name__ == "__main__":
    print("Creating tables if not exist...")
    Base.metadata.create_all(bind=engine)

    print("Applying schema patches (ALTER TABLE) for existing tables...")
    with engine.begin() as conn:
        for stmt in ALTER_STATEMENTS:
            print(f"  - {stmt}")
            conn.execute(text(stmt))

    db = SessionLocal()
    try:
        for data in SEED_EMPLOYEES:
            exists = (
                db.query(models.Employee)
                .filter(models.Employee.email == data["email"])
                .first()
            )
            if not exists:
                db.add(models.Employee(**data))
                print(f"  + seeded {data['email']} ({data['name']})")
            else:
                print(f"  = skip (already exists) {data['email']}")
        db.commit()
    finally:
        db.close()

    print("Done.")
