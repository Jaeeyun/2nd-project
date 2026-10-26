from typing import List

from fastapi import Depends, FastAPI, HTTPException
from sqlalchemy.orm import Session

import models
import schemas
from auth import get_current_hr_user
from database import get_db

app = FastAPI(title="HR Management API")

@app.middleware("http")
async def no_store_cache(request, call_next):

    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    return response

def get_manageable_employee(employee_id: int, db: Session) -> models.Employee:

    emp = db.query(models.Employee).filter(models.Employee.id == employee_id).first()
    if not emp or emp.is_hr:
        raise HTTPException(status_code=404, detail="해당 직원을 찾을 수 없습니다.")
    return emp

@app.get("/healthz")
@app.get("/api/hr/healthz")
def healthz():
    return {"status": "ok"}

@app.get("/me", response_model=schemas.EmployeeInfoResponse)
@app.get("/api/hr/me", response_model=schemas.EmployeeInfoResponse)
def read_me(hr_user: models.Employee = Depends(get_current_hr_user)):
    return hr_user

@app.get("/employees", response_model=List[schemas.EmployeeInfoResponse])
@app.get("/api/hr/employees", response_model=List[schemas.EmployeeInfoResponse])
def list_employees(
    hr_user: models.Employee = Depends(get_current_hr_user),
    db: Session = Depends(get_db),
):

    return (
        db.query(models.Employee)
        .filter(models.Employee.is_hr.is_(False))
        .order_by(models.Employee.id)
        .all()
    )

@app.post("/employees", response_model=schemas.EmployeeInfoResponse)
@app.post("/api/hr/employees", response_model=schemas.EmployeeInfoResponse)
def create_employee(
    request: schemas.EmployeeCreateRequest,
    hr_user: models.Employee = Depends(get_current_hr_user),
    db: Session = Depends(get_db),
):
    email = request.email.strip().lower()
    if db.query(models.Employee).filter(models.Employee.email == email).first():
        raise HTTPException(status_code=400, detail="이미 등록된 이메일입니다.")

    new_emp = models.Employee(
        email=email,
        name=request.name,
        department=request.department,
        position=request.position,
        salary=request.salary,
        is_hr=request.is_hr,
    )
    db.add(new_emp)
    db.commit()
    db.refresh(new_emp)

    db.add(
        models.ChangeHistory(
            employee_id=new_emp.id,
            field_name="employee_created",
            old_value=None,
            new_value=f"신규 입사 ({request.name}, {request.position})",
            changed_by=hr_user.email,
            department=request.department,
        )
    )
    db.commit()
    return new_emp

@app.get("/employees/{employee_id}", response_model=schemas.EmployeeInfoResponse)
@app.get("/api/hr/employees/{employee_id}", response_model=schemas.EmployeeInfoResponse)
def get_employee_info(
    employee_id: int,
    hr_user: models.Employee = Depends(get_current_hr_user),
    db: Session = Depends(get_db),
):
    return get_manageable_employee(employee_id, db)

@app.get("/employees/{employee_id}/salary", response_model=schemas.EmployeeSalaryResponse)
@app.get("/api/hr/employees/{employee_id}/salary", response_model=schemas.EmployeeSalaryResponse)
def get_employee_salary(
    employee_id: int,
    hr_user: models.Employee = Depends(get_current_hr_user),
    db: Session = Depends(get_db),
):
    return get_manageable_employee(employee_id, db)

@app.put("/employees/{employee_id}/position", response_model=schemas.EmployeeInfoResponse)
@app.put("/api/hr/employees/{employee_id}/position", response_model=schemas.EmployeeInfoResponse)
def update_employee_position(
    employee_id: int,
    request: schemas.PositionUpdateRequest,
    hr_user: models.Employee = Depends(get_current_hr_user),
    db: Session = Depends(get_db),
):
    employee = get_manageable_employee(employee_id, db)
    old_position = employee.position
    employee.position = request.new_position
    db.add(
        models.ChangeHistory(
            employee_id=employee.id,
            field_name="position",
            old_value=old_position,
            new_value=request.new_position,
            changed_by=hr_user.email,
            department=employee.department,
            reason=request.reason,
        )
    )
    db.commit()
    db.refresh(employee)
    return employee

@app.put("/employees/{employee_id}/salary", response_model=schemas.EmployeeSalaryResponse)
@app.put("/api/hr/employees/{employee_id}/salary", response_model=schemas.EmployeeSalaryResponse)
def update_employee_salary(
    employee_id: int,
    request: schemas.SalaryUpdateRequest,
    hr_user: models.Employee = Depends(get_current_hr_user),
    db: Session = Depends(get_db),
):
    employee = get_manageable_employee(employee_id, db)
    old_salary = employee.salary
    employee.salary = request.new_salary
    db.add(
        models.ChangeHistory(
            employee_id=employee.id,
            field_name="salary",
            old_value=str(old_salary),
            new_value=str(request.new_salary),
            changed_by=hr_user.email,
            department=employee.department,
            reason=request.reason,
        )
    )
    db.commit()
    db.refresh(employee)
    return employee

@app.get("/employees/{employee_id}/history", response_model=List[schemas.ChangeHistoryResponse])
@app.get("/api/hr/employees/{employee_id}/history", response_model=List[schemas.ChangeHistoryResponse])
def get_employee_history(
    employee_id: int,
    hr_user: models.Employee = Depends(get_current_hr_user),
    db: Session = Depends(get_db),
):
    get_manageable_employee(employee_id, db)
    return (
        db.query(models.ChangeHistory)
        .filter(models.ChangeHistory.employee_id == employee_id)
        .order_by(models.ChangeHistory.changed_at.desc())
        .all()
    )
