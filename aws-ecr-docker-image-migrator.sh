#!/bin/sh

log () {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')]: $*"
}

SOURCE_AWS_PROFILE=$1
SOURCE_CUSTOMER_ID=$2
SOURCE_REPOSITORY=$3

TARGET_AWS_PROFILE=$4
TARGET_CUSTOMER_ID=$5
TARGET_REPOSITORY=$6

if [[ ! -z "${AWS_DEFAULT_REGION}" ]]; then
    SOURCE_ECR_URL=${SOURCE_CUSTOMER_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com
    TARGET_ECR_URL=${TARGET_CUSTOMER_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com
else
    SOURCE_ECR_URL=${SOURCE_CUSTOMER_ID}.dkr.ecr.$(aws configure get region).amazonaws.com
    TARGET_ECR_URL=${TARGET_CUSTOMER_ID}.dkr.ecr.$(aws configure get region).amazonaws.com
fi

TMP_FILE=/tmp/imagePushedAt_$(date +'%Y%m%d_%H%M%S') ; > ${TMP_FILE}

eval $(AWS_PROFILE=${SOURCE_AWS_PROFILE} aws ecr get-login --no-include-email)
eval $(AWS_PROFILE=${TARGET_AWS_PROFILE} aws ecr get-login --no-include-email)

imageDigests=$(AWS_PROFILE=${SOURCE_AWS_PROFILE} aws ecr list-images --repository-name ${SOURCE_REPOSITORY} | jq -r '.imageIds[].imageDigest' | sort -u)

echo "${imageDigests}" | while read digest; do
    imagePushedAt=$(AWS_PROFILE=${SOURCE_AWS_PROFILE} aws ecr describe-images --repository-name ${SOURCE_REPOSITORY} --image-ids imageDigest=${digest} | jq -r '.imageDetails[].imagePushedAt')
    echo "${imagePushedAt},${digest}" >> ${TMP_FILE}
done

# get list of digests in ${TARGET_REPOSITORY}
# I will use that later on and check if image has been migrated already
AWS_PROFILE=${TARGET_AWS_PROFILE} aws ecr list-images --repository-name ${TARGET_REPOSITORY} | jq -r '.imageIds[].imageDigest' | sort -u > "${TMP_FILE}_target_images"

cat ${TMP_FILE} | sort | while read image; do
    digest=$(echo ${image} | cut -d',' -f2)

    if [[ ! $(grep ${digest} "${TMP_FILE}_target_images") ]]; then
        sourceImage=${SOURCE_REPOSITORY}@${digest}
        targetImage=${TARGET_REPOSITORY}@${digest}

        log "INFO: Copying from source: '${sourceImage}' to target: '${targetImage}'"

        docker pull ${SOURCE_ECR_URL}/${sourceImage}

        # 1. as we cannot push a digest reference this is a workaround
        # add 'unknown' tag to the image
        sourceImageId=$(docker image inspect ${SOURCE_ECR_URL}/${sourceImage} | jq -r .[].Id)
        docker tag ${SOURCE_ECR_URL}/${sourceImage} ${TARGET_ECR_URL}/${TARGET_REPOSITORY}:unknown

        # 2. push image with 'unknown' tag
        docker push ${TARGET_ECR_URL}/${TARGET_REPOSITORY}:unknown
        
        # 3. docker image cleanup
        docker rmi ${sourceImageId} -f &>/dev/null
        docker rmi ${TARGET_ECR_URL}/${targetImage} -f &>/dev/null

        # 4. check if source image has any imageTags; if yes add them to the target image
        tags=$(AWS_PROFILE=${SOURCE_AWS_PROFILE} aws ecr describe-images --repository-name ${SOURCE_REPOSITORY} --image-ids imageDigest=${digest} 2>/dev/null | jq -r '.imageDetails[].imageTags[]' 2>/dev/null)
        if [[ "${tags}" ]]; then
            imageManifest=$(AWS_PROFILE=${TARGET_AWS_PROFILE} aws ecr batch-get-image --repository-name ${TARGET_REPOSITORY} \
                                                              --image-ids imageTag=unknown \
                                                              --query 'images[].imageManifest' \
                                                              --output text)
            echo "${tags}" | while read tag; do
                AWS_PROFILE=${TARGET_AWS_PROFILE} aws ecr put-image --repository-name ${TARGET_REPOSITORY} --image-tag ${tag} --image-manifest "${imageManifest}"
            done
        fi

        # 5. check number of tags; if greater than 1 then remove 'unknown' tag, otherwise keep it
        # if image has only one tag you cannot just remove it and if you do that it will remove the image
        # workaround for this is to move tag to another image which has more than 1 tag and then remove it
        numberOfTags=$(AWS_PROFILE=${TARGET_AWS_PROFILE} aws ecr describe-images --repository-name ${TARGET_REPOSITORY} --image-ids imageTag=unknown 2>/dev/null | jq -r '.imageDetails[].imageTags | length')
        if [[ ${numberOfTags} -gt 1 ]]; then
            AWS_PROFILE=${TARGET_AWS_PROFILE} aws ecr batch-delete-image --repository-name ${TARGET_REPOSITORY} --image-ids imageTag=unknown
        fi
    else
        log "INFO: Image with ${digest} id already exists in ${TARGET_REPOSITORY} ECR repository and will be skipped."
    fi
done

docker rmi ${TARGET_ECR_URL}/${TARGET_REPOSITORY}:unknown -f &>/dev/null
for file in ${TMP_FILE} "${TMP_FILE}_target_images"; do
    if [[ -f "${file}" ]]; then
        rm -f ${file} &>/dev/null
    fi
done
