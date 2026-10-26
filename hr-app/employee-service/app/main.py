from typing import List

from fastapi import Depends, FastAPI
from sqlalchemy.orm import Session

import models
import schemas
from auth import get_current_employee
from database import get_db

app = FastAPI(title="Employee Self-Service API")

@app.middleware("http")
async def no_store_cache(request, call_next):

    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    return response

@app.get("/healthz")
@app.get("/api/employee/healthz")
def healthz():
    return {"status": "ok"}

@app.get("/me", response_model=schemas.EmployeeInfoResponse)
@app.get("/api/employee/me", response_model=schemas.EmployeeInfoResponse)
def read_me(employee: models.Employee = Depends(get_current_employee)):

    return employee

@app.get("/me/history", response_model=List[schemas.ChangeHistoryResponse])
@app.get("/api/employee/me/history", response_model=List[schemas.ChangeHistoryResponse])
def read_my_history(
    employee: models.Employee = Depends(get_current_employee),
    db: Session = Depends(get_db),
):

    return (
        db.query(models.ChangeHistory)
        .filter(models.ChangeHistory.employee_id == employee.id)
        .order_by(models.ChangeHistory.changed_at.desc())
        .all()
    )
