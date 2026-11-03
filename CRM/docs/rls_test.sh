P="psql -h /tmp -p 5433 -U postgres -q -t -A -d crmtest"
as() { # $1 role, $2 sub (or empty), $3 sql
  local claims; if [ -n "$2" ]; then claims="{\"sub\":\"$2\",\"role\":\"$1\"}"; else claims="{\"role\":\"$1\"}"; fi
  $P -c "BEGIN; SELECT set_config('request.jwt.claims','$claims',true); SET LOCAL ROLE $1; $3; ROLLBACK;" 2>&1 | grep -v '^$' | grep -v '^{' | paste -sd' ' -
}
A=00000000-0000-0000-0000-00000000000a; S=00000000-0000-0000-0000-00000000000b; I=00000000-0000-0000-0000-00000000000c; ST=00000000-0000-0000-0000-00000000000d; X=00000000-0000-0000-0000-00000000000e
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1: expected [$3] got [$2]"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass+1)); echo "PASS $1";; *) fail=$((fail+1)); echo "FAIL $1: expected to contain [$3] got [$2]";; esac; }

check "anon sees 0 leads"            "$(as anon '' 'SELECT count(*) FROM lead')" 0
check "non-CRM user sees 0 leads"    "$(as authenticated $X 'SELECT count(*) FROM lead')" 0
check "non-CRM user sees 0 staff"    "$(as authenticated $X 'SELECT count(*) FROM staff_directory()')" 0
check "non-CRM user sees 0 tasks"    "$(as authenticated $X 'SELECT count(*) FROM task')" 0
check "admin sees all leads"         "$(as authenticated $A 'SELECT count(*) FROM lead')" 2
check "admin sees all tasks"         "$(as authenticated $A 'SELECT count(*) FROM task')" 2
check "admin sees all employees"     "$(as authenticated $A 'SELECT count(*) FROM employee')" 3
check "admin sees attendance"        "$(as authenticated $A 'SELECT count(*) FROM cctv_attendance')" 1
check "sales sees all leads"         "$(as authenticated $S 'SELECT count(*) FROM lead')" 2
check "sales sees only own task"     "$(as authenticated $S 'SELECT title FROM task')" T-sales
check "sales sees only own employee" "$(as authenticated $S 'SELECT count(*) FROM employee')" 1
check "sales sees staff directory"   "$(as authenticated $S 'SELECT count(*) FROM staff_directory()')" 3
check "sales sees no attendance"     "$(as authenticated $S 'SELECT count(*) FROM cctv_attendance')" 0
check "sales sees all students"      "$(as authenticated $S 'SELECT count(*) FROM student')" 2
contains "sales cannot read password" "$(as authenticated $S 'SELECT password_hash FROM employee')" "permission denied"
contains "sales cannot read PIN hash" "$(as authenticated $S 'SELECT login_pin_hash FROM student')" "permission denied"
contains "sales cannot assign task to others" "$(as authenticated $S "INSERT INTO task (title,assigned_to,created_by,status) VALUES ('x','10000000-0000-0000-0000-00000000000c','10000000-0000-0000-0000-00000000000b','pending')")" "row-level security"
check "sales can add own task"       "$(as authenticated $S "INSERT INTO task (title,assigned_to,created_by,status) VALUES ('x','10000000-0000-0000-0000-00000000000b','10000000-0000-0000-0000-00000000000b','pending') RETURNING title")" x
check "instructor sees 0 leads"      "$(as authenticated $I 'SELECT count(*) FROM lead')" 0
check "instructor sees 0 students"   "$(as authenticated $I 'SELECT count(*) FROM student')" 0
check "instructor sees own task"     "$(as authenticated $I 'SELECT title FROM task')" T-instr
check "instructor can edit own phone" "$(as authenticated $I "UPDATE employee SET phone='9999' WHERE auth_user_id='$I' RETURNING phone")" 9999
contains "instructor cannot change own department" "$(as authenticated $I "UPDATE employee SET department='Admin' WHERE auth_user_id='$I'")" "Only Admin"
check "instructor cannot edit others" "$(as authenticated $I "WITH u AS (UPDATE employee SET phone='1' WHERE login_id='adm' RETURNING 1) SELECT count(*) FROM u")" 0
check "admin can change a department" "$(as authenticated $A "UPDATE employee SET department='Sales' WHERE login_id='ins' RETURNING department")" Sales
check "student sees only own row"    "$(as authenticated $ST 'SELECT first_name FROM student')" Stu
check "student sees 0 leads"         "$(as authenticated $ST 'SELECT count(*) FROM lead')" 0
check "student can update address"   "$(as authenticated $ST "UPDATE student SET address='Delhi' RETURNING address")" Delhi
contains "student cannot change course" "$(as authenticated $ST "UPDATE student SET course='ATPL'")" "Students can only update"
check "student sees 0 staff"         "$(as authenticated $ST 'SELECT count(*) FROM staff_directory()')" 0
echo "RESULT: $pass passed, $fail failed"
