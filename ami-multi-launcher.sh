#!/bin/bash

# This script invokes ami2emi.sh, takes in a long list of AMI IDs,
# and keeps track of results.  The results of each attempted AMI launch
# is logged in a separate file, AMI-xxxxxxxx.log, and the cumulative results
# are sent to stdout.  It's kind of a combination config file and batch
# manager.

# 100. Set up defaults.  The following values are sample values and
# should be changed.  
AWS_CREDS="../creds/AWS-credentials"
AWS_KEY_ID="amazon-ssh"
AWS_KEY_FILE="../creds/AWS-credentials/ssh-keys/amazon-ssh"
EUCA_CREDS="../creds/EPC-credentials"
EUCA_KEY_ID="gregdek-EPC"
EUCA_KEY_FILE="../creds/EPC-credentials/gregdek-EPC.privatekey"
EUCA_EKI_ID="eki-F33B3BF9"
EUCA_ERI_ID="eri-7A153E5C"

# 200. Start looping through IDs.
for AMI_ID in "$@"
do 
    # Run the AMI launcher.
    # Tries to bundle by default; add --no-bundle to stop this.
    # Terminates all created instances by default; add --no-terminate to stop this.
    ./ami2emi.sh \
        --aws-login "ubuntu" \
        --aws-ami ${AMI_ID} \
        --aws-creds ${AWS_CREDS} \
        --aws-key-file ${AWS_KEY_FILE} \
        --aws-key-id ${AWS_KEY_ID} \
        --euca-creds ${EUCA_CREDS} \
        --euca-key-file ${EUCA_KEY_FILE} \
        --euca-eki ${EUCA_EKI_ID} \
        --euca-eri ${EUCA_ERI_ID} \
        --no-terminate \
        --euca-key-id ${EUCA_KEY_ID} 1>logs/${AMI_ID}.log 2>logs/${AMI_ID}.err 
    # Print results based on return code.
    case $? in
        0) echo "${AMI_ID} ok" ;;
        2) echo "${AMI_ID} ERROR-2 could not source aws creds" ;;
        5) echo "${AMI_ID} ERROR-5 instance was not launched" ;;
        10) echo "${AMI_ID} ERROR-10 euca instance failed to enter running state" ;;
        20) echo "${AMI_ID} ERROR-20 could not ssh to aws instance" ;;
        30) echo "${AMI_ID} ERROR-30 could not scp to aws instance" ;;
        40) echo "${AMI_ID} ERROR-40 could not install euca2ools on aws instance" ;;
        45) echo "${AMI_ID} ERROR-45 could not source euca creds from aws" ;;
        50) echo "${AMI_ID} ERROR-50 bundle operation failed" ;;
        55) echo "${AMI_ID} ERROR-55 euca emi id not found" ;;
        60) echo "${AMI_ID} ERROR-60 could not source euca creds locally" ;;
        65) echo "${AMI_ID} ERROR-65 euca instance was not launched" ;;
        70) echo "${AMI_ID} ERROR-70 euca instance failed to enter running state" ;;
        75) echo "${AMI_ID} ERROR-75 could not ssh to euca instance" ;;
    esac
done
