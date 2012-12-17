#!/bin/bash
set -x

# The goal of this shell script is to do what's required to start an AMI instance on EC2, run
# ssh commands on that AMI, scp creds to that AMI, and bundle that AMI as an image on a totally
# different cloud.
#
# It won't be pretty like eutester or boto; it'll be ugly and dirty and will need to be rewritten by
# someone with sense.  But it's fine as a proof-of-concept.

#####
# 100. Set default variables.
# Don't ask for interactive key checking.
SSH="ssh -oStrictHostKeyChecking=no"
# Bundle to Euca by default.
NO_BUNDLE='false'
# Terminate instances by default.
NO_TERMINATE='false'
# Delete images created in Euca by default.
KEEP_IMAGE='false'
# Set size to "large" to cut timeout probability.
AMI_TYPE='m1.large'
# Set the timeout really high. Like, 10 minutes high.
AWS_TIMEOUT=600
EUCA_TIMEOUT=600
# And try a bunch of times to SSH in.  5 should do it.
AWS_SSH_TRIES=5
EUCA_SSH_TRIES=5

#####
# 120. Define functions.

terminate_aws_instance () {
    if [ ${NO_TERMINATE} == 'false' ] ; then
        echo "Terminating AWS instance ${AWS_INSTANCE_ID}"
        euca-terminate-instances ${AWS_INSTANCE_ID}
    else
        echo "--no-terminate specified, ${AWS_INSTANCE_ID} still active (remember to clean up!)"
    fi
}

terminate_euca_instance () {
    if [ ${NO_TERMINATE} == 'false' ] ; then
        echo "Terminating Euca instance ${EUCA_INSTANCE_ID}"
        euca-terminate-instances ${EUCA_INSTANCE_ID}
    else
        echo "--no-terminate specified, ${EUCA_INSTANCE_ID} still active (remember to clean up!)"
    fi
}

delete_euca_image () {
    if [ ${KEEP_IMAGE} == 'false' ] ; then
        echo "Deleting Euca image ${EMI_ID}"
        euca-delete-bundle -b amitest -p ${AMI_ID}
	euca-deregister ${EMI_ID}
    else
        echo "--keep-image specified, ${EMI_ID} still active (remember to clean up!)"
    fi
}

#####
# 150. Pull in switches.

if [ $# -eq 0 ] ; then
    echo "Usage: $0"
    echo "  --aws-login [login-id] (the shell login that the AWS instance expects)"
    echo "  --aws-ami [ami-id] (AWS AMI id to launch)"
    echo "  --aws-creds [path/to/aws/creds/dir] (AWS credentials files)"
    echo "  --aws-key-file [path/to/aws-keyfile] (AWS ssh key file)"
    echo "  --aws-key-id [aws-key-id] (AWS ssh key id)"
    echo "  --aws-metadata [path/to/aws/metadatafile] (metadata file to be fed to AWS instance)"
    echo "  --euca-creds [path/to/euca/creds/dir] (Euca creds dir to be copied to AWS instance)" 
    echo "  --euca-key-file [path/to/euca/ssh/key] (Euca ssh key file to be copied to AWS instance)" 
    echo "  --euca-key-id [euca-ssh-key-id] (Euca ssh key id)"
    echo "  --euca-eki [eki-id] (Euca EKI to associate at bundle time)"
    echo "  --euca-eri [eri-id] (Euca ERI to associate at bundle time)"
    echo "  --no-bundle (Takes no args, no bundling will be attempted)"
    echo "  --no-terminate (Takes no args, AWS instance will stay alive for debugging)"
    echo "  --keep-image (Takes no args, Euca image will stay alive for debugging)"
    exit 1
fi
while [ $# -gt 1 ] ; do
    case $1 in
        --aws-login) AWS_LOGIN=$2 ; shift 2 ;;
        --aws-ami) AMI_ID=$2 ; shift 2 ;;
        --aws-creds) AWS_CREDS=$2 ; shift 2 ;;
        --aws-key-file) AWS_KEY_FILE=$2 ; shift 2 ;;
        --aws-key-id) AWS_KEY_ID=$2 ; shift 2 ;;
        --euca-creds) EUCA_CREDS=$2 ; shift 2 ;;
        --euca-key-file) EUCA_KEY_FILE=$2 ; shift 2 ;;
        --euca-key-id) EUCA_KEY_ID=$2 ; shift 2 ;;
        --euca-eki) EUCA_EKI_ID=$2 ; shift 2 ;;
        --euca-eri) EUCA_ERI_ID=$2 ; shift 2 ;;
        --no-bundle) NO_BUNDLE='true' ; shift 1 ;;
        --no-terminate) NO_TERMINATE='true' ; shift 1 ;;
        --keep-image) KEEP_IMAGE='true' ; shift 1 ;;
         *) shift 1 ;;
    esac
done

#####
# 195. Source the local eucarc for AWS.
source ${AWS_CREDS}/eucarc
if [ $? -ne 0 ]; then
    echo "FATAL: could not source AWS creds"
    exit 2
fi

#####
# 200. Start an AWS instance and grab the instance ID. Ex: i-12345678
# Note that we should bail if we don't actually get an ID.
AWS_INSTANCE_ID=`euca-run-instances ${AMI_ID} -k ${AWS_KEY_ID} -t ${AMI_TYPE} | perl -ne '/\s(i-\S{8})/ && print $1'`
# Is AWS_INSTANCE_ID null?
if [ -z ${AWS_INSTANCE_ID} ] 
then
    echo "FATAL: Instance not started (possibly an AMI that requires TOS?)"
    exit 5
fi

#####
# 210. Every 15 seconds, poll that instance until you see that it's running.
# When "running" shows up in euca-describe-instances with the right instance
# ID, pull the IP address and pass along.
AWS_INSTANCE_RUNNING=1 
while [ "${AWS_INSTANCE_RUNNING}" -eq "1" ]
do
    echo "  Waiting for instance to start, timeout in ${AWS_TIMEOUT}"
    sleep 10
    let "AWS_TIMEOUT -= 10"
    if [ "${AWS_TIMEOUT}" -le "0" ] 
    then
        echo "Timeout waiting for AWS instance to start"
        terminate_aws_instance
        exit 10 
    fi
    # greps for both instance id and "running" in the same line,
    # and reset AWS_INSTANCE_RUNNING if both are found
    euca-describe-instances | grep ${AWS_INSTANCE_ID} | grep "running" && let "AWS_INSTANCE_RUNNING=0"
done
echo "${AWS_INSTANCE_ID} started successfully"

#####
# 220. ssh to the IP address (cut column 4 from euca-describe-instances) and run a command
# to establish connection.  For now we're always ssh'ing in as root.  We know that this
# will not be sufficient for many images, but it's where we will start.  Note also that
# we cannot yet count on the presence of cloud-init to help us out, so we will be running
# all subsequent commands thru SSH directly.
# 
# We also need to figure out a way to parse which user ID we should be logging in as.
# Some are "root", some are "ubuntu", some may be others.  For now, this is passed in
# as an argument, since we have some expectations: ubuntu users tend to require login
# as the ubuntu user.
#
# TODO: split this into a "ssh to see if it accepts connections" with longer timeout,
# and then try subsequent connections with various usernames.  Walk through root, ubuntu,
# etc.

AWS_HOSTNAME=`euca-describe-instances | grep ${AWS_INSTANCE_ID} | cut -f4`
echo "Hostname found: ${AWS_HOSTNAME}"
SSHCMD="${SSH} -i ${AWS_KEY_FILE} ${AWS_LOGIN}@${AWS_HOSTNAME}" 
SCPCMD="scp -i ${AWS_KEY_FILE}"
# Now connect. Keep trying.
AWS_SSH_UP=1
while [ "${AWS_SSH_UP}" -ne "0" ]
do
    echo "sshing to host: ${AWS_SSH_TRIES} left"
    echo "${SSHCMD} cat /etc/motd"
    ${SSHCMD} "cat /etc/motd"
    # did ssh work? if so, set ssh to be up.
    if [ $? -eq "0" ]; then
        let "AWS_SSH_UP=0"
    fi
    # did we fail repeatedly? if so, exit.
    if [ $AWS_SSH_TRIES -le "0" ]; then
        echo "timeout trying to ssh"
        terminate_aws_instance
        exit 20
    fi
    let "AWS_SSH_TRIES-=1"
    # did we fail, but not enough yet? wait 30 seconds to try again
    if [ "${AWS_SSH_UP}" -ne "0" ]; then
        echo "  waiting 30 seconds for next attempt"
        sleep 30
    fi
done

echo "Connection to ${AWS_HOSTNAME} established"

#####
# 300. Determine the OS. This is a stub. Right now
#   we're assuming Ubuntu.

#####
# 400. List the modules in our ramdisk.
#   Run lsinitrd or lsinitramfs on /boot/initram* and
#   look for things we like.  If we don't find them,
#   bail and set status accordingly.
#   (NOTE: check Andy's email here.)
#   Also a stub for now.

#####
# 500. scp over the creds files.
# Now try to scp this file into tmp.  
${SCPCMD} -r ${EUCA_CREDS} ${AWS_LOGIN}@${AWS_HOSTNAME}:/tmp/euca_creds
${SCPCMD} ${EUCA_KEY_FILE} ${AWS_LOGIN}@${AWS_HOSTNAME}:/tmp/
if [ $? -ne 0 ]; then
    cat "FATAL: could not scp (no scp on remote system?)"
    terminate_aws_instance
    exit 30
fi

#####
# 600. Install euca2ools on remote host, assume Ubuntu.
${SSHCMD} "sudo apt-get install -y euca2ools"
if [ $? -ne 0 ]; then
    cat "FATAL: could not install euca2ools"
    terminate_aws_instance
    exit 40
fi

#####
# 650. WRITE BUNDLING SCRIPT.
# Write a local bundling script that either exits with error or returns
# the emi-id to stdout.  We write it dynamically because we need to plug
# in variables, although in future we could abstract this out into a
# separate script that we call with args.
(
cat <<EOF
#!/bin/bash
set -x
# Empty out the Ubuntu persistent-net rules
cat /dev/null > /etc/udev/rules.d/70-persistent-net.rules
source /tmp/euca_creds/eucarc
# euca-bundle-vol -p ${AMI_ID} -d /mnt/ -e /var/lib/dhcp/ -s 4096 --generate-fstab --kernel ${EUCA_EKI_ID} --ramdisk ${EUCA_ERI_ID}
euca-bundle-vol -p ${AMI_ID} -d /mnt/ -e /var/lib/dhcp/ -s 4096 --kernel ${EUCA_EKI_ID} --ramdisk ${EUCA_ERI_ID}
euca-upload-bundle -b amitest -m /mnt/${AMI_ID}.manifest.xml
if [ \$? -ne 0 ]; then
    cat "FATAL: euca-upload-bundle failed"
    exit 50
fi
euca-register amitest/${AMI_ID}.manifest.xml
#   (also works, returns image ID, in this case emi-9DC83D86)
EOF
) > /tmp/ami-bundle.sh

#####
# 650. SCP BUNDLE SCRIPT TO INSTANCE AND RUN IT.
# scp the script to the remote machine, chown it to root, 
# setuid on it, and then sudo the whole script.  We do this 
# because we want to be sure that the sourcing of euca 
# credentials is consistent across the entire script.
if [[ $NO_BUNDLE=='false' ]]; then
    ${SCPCMD} /tmp/ami-bundle.sh ${AWS_LOGIN}@${AWS_HOSTNAME}:/tmp/
    ${SSHCMD} "sudo chown root:root /tmp/ami-bundle.sh"
    ${SSHCMD} "sudo chmod 4755 /tmp/ami-bundle.sh"
    ${SSHCMD} "sudo /tmp/ami-bundle.sh" > /tmp/ami-bundle.${AMI_ID}.out
    if [ $? -ne 0 ]; then
        cat "FATAL: could not create or upload bundle"
        terminate_aws_instance
        exit 50
    fi
else
    echo "--no-bundle specified, bundling skipped"
fi

#####
# 700. GET THE EMI ID.
# parse the data from /tmp/ami-bundle to get the new EMI,
# and then run that EMI through a basic test.
EMI_ID=`tail -n 1 /tmp/ami-bundle.${AMI_ID}.out | perl -ne '/(emi-\S{8})/ && print $1'`
# Is EMI_ID null?
if [ -z ${EMI_ID} ] 
then
    echo "FATAL: EMI ID not found, did EMI creation fail?"
    terminate_aws_instance
    exit 55
fi

#####
# 705. Source the Euca creds.
source ${EUCA_CREDS}/eucarc
if [ $? -ne 0 ]; then
    echo "FATAL: could not source Euca creds"
    terminate_aws_instance
    delete_euca_image
    exit 60
fi

#####
# 710. Start a Euca instance!
# Start the instance and grab the instance ID. Ex: i-12345678
# Note that we should bail if we don't actually get an ID.
EUCA_INSTANCE_ID=`euca-run-instances ${EMI_ID} -k ${EUCA_KEY_ID} -t ${AMI_TYPE} | perl -ne '/(i-\S{8})/ && print $1'`
if [ -z ${EUCA_INSTANCE_ID} ]
then
    echo "FATAL: Euca instance not started"
    terminate_aws_instance
    delete_euca_image
    exit 65
fi

#####
# 720. Every 15 seconds, poll that instance until you see that it's running.
# When "running" shows up in euca-describe-instances with the right instance
# ID, pull the IP address and pass along.
EUCA_INSTANCE_RUNNING=1 
while [ "${EUCA_INSTANCE_RUNNING}" -eq "1" ]
do
    echo "  Waiting for instance to start, timeout in ${EUCA_TIMEOUT}"
    sleep 10
    let "EUCA_TIMEOUT -= 10"
    if [ "${EUCA_TIMEOUT}" -le "0" ] 
    then
        echo "Timeout waiting for Euca instance to reaching RUNNING state"
        terminate_aws_instance
        terminate_euca_instance
        delete_euca_image
        exit 70
    fi
    # greps for both instance id and "running" in the same line,
    # and reset EUCA_INSTANCE_RUNNING if both are found
    euca-describe-instances | grep ${EUCA_INSTANCE_ID} | grep "running" && let "EUCA_INSTANCE_RUNNING=0"
done
echo "${EUCA_INSTANCE_ID} started successfully"

#####
# 750. Try to ssh in.  If we fail after 5 tries, spit out the results of
# "euca-get-console-output" to /tmp/console-${EUCA_INSTANCE_ID}.log and
# tail the last few lines to stdout.  We're also going to assume that
# the login is the same as on the image we're ripping.

EUCA_LOGIN=${AWS_LOGIN}
EUCA_HOSTNAME=`euca-describe-instances | grep ${EUCA_INSTANCE_ID} | cut -f4`
echo "Hostname found: ${EUCA_HOSTNAME}"
SSHCMD="${SSH} -i ${EUCA_KEY_FILE} ${EUCA_LOGIN}@${EUCA_HOSTNAME}"
SCPCMD="scp -i ${EUCA_KEY_FILE}"
# Now connect. Keep trying.
EUCA_SSH_UP=1
while [ "${EUCA_SSH_UP}" -ne "0" ]
do
    echo "sshing to host: ${EUCA_SSH_TRIES} left"
    echo "${SSHCMD} cat /etc/motd"
    ${SSHCMD} "cat /etc/motd"
    # did ssh work? if so, set ssh to be up.
    if [ $? -eq "0" ]; then
        let "EUCA_SSH_UP=0"
    fi
    # did we fail repeatedly? if so, exit.
    if [ $EUCA_SSH_TRIES -le "0" ]; then
        echo "timeout trying to ssh to Euca"
        euca-get-console-output ${EUCA_INSTANCE_ID} > /tmp/console-${EUCA_INSTANCE_ID}.log
        echo "********************************"
        echo "* tail -n 25 of Euca console:  *"
        echo "********************************"
        tail -n 25 /tmp/console-${EUCA_INSTANCE_ID}.log
        echo "********************************"
        echo "See /tmp/console-${EUCA_INSTANCE_ID}.log for full output"
        terminate_euca_instance
        terminate_aws_instance
        delete_euca_image
        exit 75
    fi
    let "EUCA_SSH_TRIES-=1"
    # did we fail, but not enough yet? wait 30 seconds to try again
    if [ "${EUCA_SSH_UP}" -ne "0" ]; then
        echo "  waiting 30 seconds for next attempt"
        sleep 30
    fi
done

#####
# 999. Exit normally.
terminate_euca_instance
terminate_aws_instance
delete_euca_image
exit 0

