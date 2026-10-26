from sqlalchemy import Boolean, Column, DateTime, Integer, String, func
from database import Base

class Employee(Base):
    __tablename__ = "employees"

    id = Column(Integer, primary_key=True, index=True)
    email = Column(String, unique=True, nullable=False, index=True)
    name = Column(String, nullable=False)
    department = Column(String, nullable=False, index=True)
    position = Column(String, nullable=False)
    salary = Column(Integer, nullable=False)
    is_hr = Column(Boolean, nullable=False, default=False)

class ChangeHistory(Base):
    __tablename__ = "change_history"

    id = Column(Integer, primary_key=True, index=True)
    employee_id = Column(Integer, nullable=False, index=True)
    field_name = Column(String, nullable=False)
    old_value = Column(String)
    new_value = Column(String)
    changed_by = Column(String, nullable=False)
    department = Column(String, nullable=False, index=True)
    reason = Column(String, nullable=True)
    changed_at = Column(DateTime(timezone=True), server_default=func.now())
