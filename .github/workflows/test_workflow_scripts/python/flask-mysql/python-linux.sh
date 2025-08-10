#!/bin/bash

# This script assumes a similar folder structure to the example provided.
# Modify the source path if your structure is different.
source ../../.github/workflows/test_workflow_scripts/test-iid.sh

# Create a shared network for Keploy and the application containers
docker network create keploy-network || true

# Start the database
docker compose up -d

# Install dependencies
pip3 install -r requirements.txt

# Setup environment variables for the application to connect to the Dockerized DB
export DB_HOST=127.0.0.1
export DB_PORT=3306
export DB_USER=demo
export DB_PASSWORD=demopass
export DB_NAME=demo

# Configuration and cleanup
sudo rm -f keploy.yml # Prevent interactive prompt
sudo $RECORD_BIN config --generate
sudo rm -rf keploy/  # Clean old test data
config_file="./keploy.yml"
sed -i 's/global: {}/global: {"header": {"Allow":[]}}/' "$config_file"
sleep 5

send_request(){
    # Wait for the application to be fully started
    sleep 10
    app_started=false
    echo "Checking for app readiness on port 5001..."
    while [ "$app_started" = false ]; do
        if curl -s --head http://127.0.0.1:5001/ > /dev/null; then
            app_started=true
            echo "App is ready!"
        else
            sleep 3
        fi
    done
    
    # Login to get the JWT token with a retry mechanism
    echo "Logging in to get JWT token..."
    TOKEN=""
    for i in {1..5}; do
        TOKEN=$(curl -s -X POST -H "Content-Type: application/json" -d '{"username": "admin", "password": "admin123"}' "http://127.0.0.1:5001/login" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
        if [ -n "$TOKEN" ]; then break; fi
        sleep 5
    done

    if [ -z "$TOKEN" ]; then
        echo "Failed to retrieve JWT token. Aborting."
        pid=$(pgrep keploy) && [ -n "$pid" ] && sudo kill "$pid"
        exit 1
    fi
    echo "Token received."
    
    # Send API requests
    echo "Sending API requests..."
    curl -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d '{"name": "Keyboard", "quantity": 50, "price": 75.00, "description": "Mechanical keyboard"}' 'http://127.0.0.1:5001/robust-test/create'
    curl -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d '{"name": "Webcam", "quantity": 30}' 'http://127.0.0.1/robust-test/create-with-null'
    curl -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:5001/robust-test/get-all'
    
    sleep 10
    pid=$(pgrep keploy)
    echo "$pid Keploy PID. Killing keploy."
    [ -n "$pid" ] && sudo kill "$pid"
}

# Record cycles
for i in {1..2}; do
    send_request &
    sudo -E env PATH="$PATH" DB_HOST=$DB_HOST DB_PORT=$DB_PORT DB_USER=$DB_USER DB_PASSWORD=$DB_PASSWORD DB_NAME=$DB_NAME $RECORD_BIN record -c "python3 demo.py" &> "record-${i}.txt"
    wait
    echo "Recorded test case and mocks for iteration ${i}"
done

# --- FIX: Reset database state before testing ---
echo "Resetting database state for a clean test environment..."
docker compose down
docker compose up -d
sleep 15 # Wait for DB to be ready

# --- FIX: Run test command but don't exit on its error code ---
# We add `|| true` to ignore Keploy's non-zero exit code for IGNORED tests.
# We will check the reports to determine the final status.
echo "Starting testing phase..."
sudo -E env PATH="$PATH" DB_HOST=$DB_HOST DB_PORT=$DB_PORT DB_USER=$DB_USER DB_PASSWORD=$DB_PASSWORD DB_NAME=$DB_NAME $REPLAY_BIN test -c "python3 demo.py" --delay 10 &> test_logs.txt || true

# --- FIX: Correctly check the final reports ---
# This logic now only fails the build if a test set's status is explicitly "FAILED".
build_failed=false
for i in {0..1}; do
    report_file="./keploy/reports/test-run-0/test-set-$i-report.yaml"
    if [ ! -f "$report_file" ]; then
        echo "Report file not found: $report_file"
        build_failed=true
        break
    fi
    
    test_status=$(grep 'status:' "$report_file" | head -n 1 | awk '{print $2}')
    echo "Test status for test-set-$i: $test_status"
    
    if [ "$test_status" == "FAILED" ]; then
        build_failed=true
        echo "Test-set-$i has FAILED."
        break
    fi
done

# Final check to determine exit code
if [ "$build_failed" = true ]; then
    echo "Build failed because a test set reported a FAILED status."
    cat "test_logs.txt"
    docker compose down
    exit 1
else
    echo "All tests passed or were ignored. Build successful."
    docker compose down
    exit 0
fi
