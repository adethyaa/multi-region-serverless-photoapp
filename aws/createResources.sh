#!/usr/bin/env bash

srcBktArr=();
STACK_DTLS=();

checkNgEnv() {

    if hash npm 2>/dev/null; then
      echo "npm available"
    else
      echo "install npm"
      exit 1;
    fi  
    
    if [ ! -d "$NPM_DIR" ]; then
        npm install
    fi
    cd ..

    echo "Checking wheather Angular cli(ng) is installed"
    if hash ng 2>/dev/null; then
        echo "ng is installed"
    else
        echo "Installing Angular cli"
        npm install -g @angular/cli &
    fi
    cd -
}

createResource() {
    for i in "${array[@]}"
    do
        echo "Deploying stack in "$i;
        SRC_BUK_NAME="src"$(date +%s)$RANDOM
        srcBktArr+=($SRC_BUK_NAME)
        aws s3 mb s3://$SRC_BUK_NAME --region $i
        aws s3 cp ./lambda s3://$SRC_BUK_NAME/ --recursive --region $i 
        aws cloudformation deploy --region $i --template ./templates/GlblSrvlsApp.yaml --stack-name $ROOT_NAME --capabilities CAPABILITY_IAM --parameter-overrides BucketName=$SRC_BUK_NAME FacebookId=$FACEBOOK_ID > /tmp/output.txt &
    done
    wait;
}

enableCRR() {
    
    CRR_ROLE=();
    GALLERY_BKT=();
    for i in 0 1
        do
            CRR_ROLE+=($(getCRRRole "${STACK_DTLS[$i]}"));
            GALLERY_BKT+=($(getGlrBcktName "${STACK_DTLS[$i]}"));
        done
    
    aws s3api put-bucket-replication --bucket ${GALLERY_BKT[0]} --replication-configuration "{
          \"Role\": \"${CRR_ROLE[0]}\",
          \"Rules\": [
            {
              \"Prefix\": \"\",
              \"Status\": \"Enabled\",
              \"Destination\": {
                \"Bucket\": \"arn:aws:s3:::${GALLERY_BKT[1]}\"
              }
            }
          ]
        }";    
    aws s3api put-bucket-replication --bucket ${GALLERY_BKT[1]} --replication-configuration "{
          \"Role\": \"${CRR_ROLE[1]}\",
          \"Rules\": [
            {
              \"Prefix\": \"\",
              \"Status\": \"Enabled\",
              \"Destination\": {
                \"Bucket\": \"arn:aws:s3:::${GALLERY_BKT[0]}\"
              }
            }
          ]
        }";
}

createGlobalDDB() {
    TABLE_NAME="_ImgMetadata";
    aws dynamodb create-global-table \
        --global-table-name $ROOT_NAME$TABLE_NAME \
        --replication-group RegionName=${array[0]} RegionName=${array[1]} \
        --region ${array[0]}
}       

getStackOutput() {
     for i in "${array[@]}"
        do
            STACK_DTLS+=("$(aws cloudformation describe-stacks --region $i --stack-name  $ROOT_NAME --output text --query 'Stacks[0].Outputs[*].[OutputKey, OutputValue]')")
     done
}

getCRRRole(){
    value=$(sed -n 's/.*S3ReplAccessRoleId \([^ ]*\).*/\1/p' <<< $1)
    echo $value
}

getGlrBcktName(){
    value=$(sed -n 's/.*GalleryS3Bucket \([^ ]*\).*/\1/p' <<< $1)
    echo $value
}

getAppBcktName(){
    value=$(sed -n 's/.*GlblSrvrLessAppBucket \([^ ]*\).*/\1/p' <<< $1)
    echo $value
}

getAPIUrl(){
    value=$(sed -n 's/.*ApiUrl \([^ ]*\).*/\1/p' <<< $1)
    echo $value
}

getIdenPoolId(){
    value=$(sed -n 's/.*CognitoIdentityPoolId \([^ ]*\).*/\1/p' <<< $1)
    echo $value
}

buildCopyWebApp() {
    cd $ROOT_DIR
    pwd
    for i in 0 1
    do
        apiURL=$(getAPIUrl "${STACK_DTLS[$i]}");
        identityPoolId=$(getIdenPoolId "${STACK_DTLS[$i]}");
        appS3Bucket=$(getAppBcktName "${STACK_DTLS[$i]}")
        writeConfigFiles "${array[$i]}" "$apiURL" "$identityPoolId";
        ng build --prod --aot
        aws s3 cp $ROOT_DIR/dist/ s3://"$appS3Bucket"/ --recursive 
    done
 }

 deleteSrcBucket() {
    for i in "${srcBktArr[@]}"
    do
      echo "deleting bucket : "$i
      aws s3 rb s3://$i --force
    done
 }

printConfig() {
    echo " ****************************************************** "
    for i in 0 1
    do
      echo "Resource references for region ${array[$i]} are : "
      echo "  "
      echo "${STACK_DTLS[$i]}"
      echo " ****************************************************** "
    done
}

writeConfigFiles() {
(
cat <<EOF

export const environment = {
  production: false,
  region: '$1',
  apiUrl: '$2',
  identityPoolId: '$3',
  fbId:'$FACEBOOK_ID'
};

EOF
) > $ROOT_DIR/src/environments/environment.ts

(
cat <<EOF
export const environment = {
  production: true,
  region: '$1',
  apiUrl: '$2',
  identityPoolId: '$3',
  fbId:'$FACEBOOK_ID'
};

EOF
) > $ROOT_DIR/src/environments/environment.prod.ts

}

echo -n "Enter a name for your cloud formation stack (must be all lowercase with no spaces) and press [ENTER]: "
read ROOT_NAME

if [[ $ROOT_NAME =~ [[:upper:]]|[[:space:]] || -z "$ROOT_NAME" ]]; then
    echo "Invalid format"
    exit 1
fi

    echo -n "Enter your Facebook App ID : "
    read FACEBOOK_ID

    echo -n "Enter 2 regions seperated by space eg: us-east-1 us-east-2 "
    read -a array
     
    if [ ${#array[@]} -ne 2 ] 
        then
            echo "Enter exactly 2 regions for deployment"  
            exit 1  
        fi 
    CURR_DIR=$( cd $(dirname $0) ; pwd -P )
    ROOT_DIR=$( cd $CURR_DIR; cd ..; pwd -P)

    NPM_DIR=$ROOT_DIR/node_modules/

    checkNgEnv
    createResource
    getStackOutput
    buildCopyWebApp
    enableCRR
    createGlobalDDB
    deleteSrcBucket
    printConfig

