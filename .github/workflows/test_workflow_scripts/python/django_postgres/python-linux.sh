#!/bin/bash

source ../../.github/workflows/test_workflow_scripts/test-iid.sh

# Checkout to the specified branch
git fetch origin
git checkout native-linux

# Start the postgres database
docker compose up -d

# Install dependencies
pip3 install -r requirements.txt

# Setup environment
export PYTHON_PATH=./venv/lib/python3.10/site-packages/django

# Database migrations
python3 manage.py makemigrations
python3 manage.py migrate

# Configuration and cleanup
sudo $RECORD_BIN config --generate
sudo rm -rf keploy/  # Clean old test data
config_file="./keploy.yml"
sed -i 's/global: {}/global: {"header": {"Allow":[],}}/' "$config_file"
sleep 5

send_request(){
    sleep 10
    app_started=false
    while [ "$app_started" = false ]; do
        if curl -X GET http://127.0.0.1:8000/; then
            app_started=true
        fi
        sleep 3 # wait for 3 seconds before checking again.
    done
    echo "App started"
    # Start making curl calls to record the testcases and mocks.
    curl --location 'http://127.0.0.1:8000/user/' --header 'Content-Type: application/json' --data-raw '{
        "name": "Jane Smith",
        "email": "jane.smith@example.com",
        "password": "smith567",
        "website": "www.janesmith.com"
    }'
    curl --location 'http://127.0.0.1:8000/user/' --header 'Content-Type: application/json' --data-raw '{
        "name": "John Doe",
        "email": "john.doe@example.com",
        "password": "john567",
        "website": "www.johndoe.com"
    }'
    curl --location 'http://127.0.0.1:8000/user/'
    # Wait for 10 seconds for keploy to record the tcs and mocks.
    sleep 10
    pid=$(pgrep keploy)
    echo "$pid Keploy PID" 
    echo "Killing keploy"
    sudo kill $pid
}

# Record and Test cycles
for i in {1..2}; do
    app_name="flaskApp_${i}"
    send_request &
    sudo -E env PATH="$PATH" $RECORD_BIN record -c "python3 manage.py runserver"   &> "${app_name}.txt"
    if grep "ERROR" "${app_name}.txt"; then
        echo "Error found in pipeline..."
        cat "${app_name}.txt"
        exit 1
    fi
    if grep "WARNING: DATA RACE" "${app_name}.txt"; then
        echo "Race condition detected in recording, stopping pipeline..."
        cat "${app_name}.txt"
        exit 1
    fi
    sleep 5
    wait
    echo "Recorded test case and mocks for iteration ${i}"
done

# Sanity: ensure we actually have recorded tests by checking for test-set-* directories
if [ -z "$(ls -d ./keploy/test-set-* 2>/dev/null)" ]; then
  echo "No recorded test sets (e.g., test-set-0) found in ./keploy/. Did recording succeed?"
  echo "Contents of ./keploy/ directory:"
  ls -la ./keploy || echo "./keploy directory not found."
  exit 1
fi

echo "✅ Sanity check passed. Found recorded test sets."

echo "Starting testing phase with up to 5 attempts..."

for attempt in {1..5}; do
    echo "--- Test Attempt ${attempt}/5 ---"

    # Reset database state for a clean test environment before each attempt
    echo "Resetting database state for attempt ${attempt}..."
    docker compose down
    docker compose up -d

    # Wait for PostgreSQL to be ready
    echo "Waiting for DB on 127.0.0.1:5432..."
    db_ready=false
    for i in {1..30}; do
        if nc -z 127.0.0.1 5432 2>/dev/null; then
            echo "DB port is open."
            db_ready=true
            break
        fi
        sleep 2
    done

    if [ "$db_ready" = false ]; then
        echo "DB failed to become ready for attempt ${attempt}. Retrying..."
        continue # Skip to the next attempt
    fi

    sleep 10 # Extra wait time for DB initialization

    # Run database migrations again for clean state
    python3 manage.py makemigrations
    python3 manage.py migrate

    # Run the test for the current attempt
    log_file="test_logs_attempt_${attempt}.txt"
    echo "Running Keploy test for attempt ${attempt}, logging to ${log_file}"

    set +e
    sudo -E env PATH="$PATH" "$REPLAY_BIN" test -c "python3 manage.py runserver" --delay 10 &> "${log_file}"
    TEST_EXIT_CODE=$?
    set -e

    echo "Keploy test (attempt ${attempt}) exited with code: $TEST_EXIT_CODE"
    echo "----- Keploy test logs (attempt ${attempt}) -----"
    cat "${log_file}"
    echo "-------------------------------------------"

    # Check for generic errors or data races in logs first
    if grep -q "ERROR" "${log_file}"; then
        echo "❌ Test Attempt ${attempt} Failed. Found ERROR in logs."
        if [ "$attempt" -lt 5 ]; then
            echo "Retrying..."
            sleep 5
            continue
        else
            break
        fi
    fi
    
    # Check individual test reports for PASSED status
    all_passed_in_attempt=true
    # The recording loop runs twice {1..2}, so we expect test-set-0 and test-set-1
    for i in {0..1}; do
        report_file="./keploy/reports/test-run-0/test-set-$i-report.yaml"

        if [ ! -f "$report_file" ]; then
            echo "Report file not found for test-set-$i. Marking attempt as failed."
            all_passed_in_attempt=false
            break
        fi

        test_status=$(grep 'status:' "$report_file" | head -n 1 | awk '{print $2}')
        echo "Test status for test-set-$i: $test_status"

        if [ "$test_status" != "PASSED" ]; then
            all_passed_in_attempt=false
            echo "Test-set-$i did not pass."
            break
        fi
    done

    if [ "$all_passed_in_attempt" = true ]; then
        echo "✅ All tests passed on attempt ${attempt}!"
        docker compose down
        exit 0 # Successful exit from the script
    fi

    # If we reach here, the attempt failed.
    echo "❌ Test Attempt ${attempt} Failed. Not all reports were PASSED."
    if [ "$attempt" -lt 5 ]; then
        echo "Retrying..."
        sleep 5
    fi
done

# If the loop completes, all attempts have failed.
echo "🔴 All 5 test attempts failed. Exiting with failure."
docker compose down
exit 1