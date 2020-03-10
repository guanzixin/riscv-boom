#!/bin/bash

# -------------------------------------------------------------
# init manager with chipyard and firesim as a library
# do firesim managerinit (don't need to do it in future setups)
# add version of boom (override older version)
# -------------------------------------------------------------

# turn echo on and error on earliest command
set -ex

SCRIPT_DIR="$( cd "$( dirname "$0" )" && pwd )"
echo "$SCRIPT_DIR"

# install rsync
sudo apt-get install -y rsync

# get the firesim instance launch script
git clone --progress --verbose https://github.com/ucb-bar/chipyard.git
cd chipyard
echo "Checking out Chipyard version: $(cat $HOME/project/CHIPYARD.hash)"
git fetch
git checkout $(cat $HOME/project/CHIPYARD.hash)
cd sims
git submodule update --init firesim/
cp firesim/scripts/machine-launch-script.sh $HOME/firesim-instance-launch-script.sh

cd $HOME

# add expect to the install
echo "sudo yum -y install expect" >> firesim-instance-launch-script.sh
echo "echo \"firesim-ci: installed expect\" >> /home/centos/machine-launchstatus" >> firesim-instance-launch-script.sh

# get the resize root script
cp $HOME/project/.circleci/firesim-instance-resize-root.json .

# launch manager with cli
aws ec2 run-instances \
    --image-id ami-0e560af290c745f5b \
    --count 1 \
    --instance-type c5.9xlarge \
    --key-name firesim \
    --security-group-ids sg-07a0a7896e773a564 \
    --subnet-id subnet-0f0b813740c8ec84d \
    --block-device-mappings file://firesim-instance-resize-root.json \
    --user-data file://firesim-instance-launch-script.sh \
    --associate-public-ip-address &> output.json

# location of the file with instance-id and ip-address of the firesim manager
INSTANCE_FILE=/tmp/FSIM_MANAGER_INSTANCE_DATA.txt

# get the instance id
grep InstanceId output.json | sed -r 's/.*InstanceId.*\"(.*)\",.*/\1/' &> $INSTANCE_FILE

# wait for mins for instance to boot/install items
sleep 3m

# get the assigned public ip address
aws ec2 describe-instances --instance-ids $(cat $INSTANCE_FILE) &> output.json
grep PublicIpAddress output.json | sed -r 's/.*PublicIpAddress.*\"(.*)\",.*/\1/' >> $INSTANCE_FILE

# setup AWS_SERVER variable
AWS_SERVER=centos@$(sed -n '2p' $INSTANCE_FILE)

# get back to initial folder
cd $HOME/project

# get shared variables
source $SCRIPT_DIR/defaults.sh

# set stricthostkeychecking to no (must happen before rsync)
run_aws "echo \"Ping $AWS_SERVER\""
run "echo \"Ping $AWS_SERVER\""

# copy over the firesim.pem
# note: this is a bit of a hack to get around you not being able to upload an env. var. into CircleCI with \n's
echo $FIRESIM_PEM | tr , '\n' > firesim.pem
copy firesim.pem $AWS_SERVER:$CI_AWS_DIR/

# copy over the spec iso from the build server to the manager instance
copy $SERVER:$REMOTE_SPEC $HOME/spec-2017.iso
copy $HOME/spec-2017.iso $AWS_SERVER:$CI_AWS_DIR/
rm -rf $HOME/spec-2017.iso

# clear folders older than 30 days
run_script_aws $SCRIPT_DIR/clean-old-files.sh $CI_AWS_DIR

SCRIPT_NAME=firesim-manager-setup.sh

# create a script to run
cat <<EOF >> $LOCAL_CHECKOUT_DIR/$SCRIPT_NAME
#!/bin/bash

set -ex

mkdir -p $REMOTE_AWS_WORK_DIR
cd $REMOTE_AWS_WORK_DIR

# install spec
mkdir -p $SPEC_SRC_DIR
sudo mount $CI_AWS_DIR/spec-2017.iso $SPEC_SRC_DIR -o loop
cd $SPEC_SRC_DIR

/bin/expect << EXP
set timeout -1
spawn ./install.sh
send -- "$SPEC_DIR\r"
send -- "yes\r"
expect eof
EXP

# expect folder to install to
# expect yes

# get chipyard
cd $REMOTE_AWS_WORK_DIR
rm -rf $REMOTE_AWS_CHIPYARD_DIR
git clone --progress --verbose https://github.com/ucb-bar/chipyard.git $REMOTE_AWS_CHIPYARD_DIR
cd $REMOTE_AWS_CHIPYARD_DIR
echo "Checking out Chipyard version: $(cat $LOCAL_CHECKOUT_DIR/CHIPYARD.hash)"
git fetch
git checkout $(cat $LOCAL_CHECKOUT_DIR/CHIPYARD.hash)

# setup repo
./scripts/init-submodules-no-riscv-tools.sh
./scripts/firesim-setup.sh --fast

# setup firesim and firemarshal
chmod 600 $CI_AWS_DIR/firesim.pem
cd $REMOTE_AWS_FSIM_DIR
source sourceme-f1-manager.sh
cd $REMOTE_AWS_MARSHAL_DIR
./init-submodules.sh
cd $REMOTE_AWS_FSIM_DIR

# use expect to send newlines to managerinit (for some reason heredoc errors on email input)
/bin/expect << EXP
set timeout -1
spawn firesim managerinit
send -- "$AWS_ACCESS_KEY_ID\r"
send -- "$AWS_SECRET_ACCESS_KEY\r"
send -- "$AWS_DEFAULT_REGION\r"
send -- "json\r"
send -- "\r"
expect eof
EXP

# remove boom so it can get added properly
rm -rf $REMOTE_AWS_CHIPYARD_DIR/generators/boom
EOF

# execute the script
chmod +x $LOCAL_CHECKOUT_DIR/$SCRIPT_NAME
run_script_aws $LOCAL_CHECKOUT_DIR/$SCRIPT_NAME

# add checkout boom to repo
copy $LOCAL_CHECKOUT_DIR/ $AWS_SERVER:$REMOTE_AWS_CHIPYARD_DIR/generators/boom/