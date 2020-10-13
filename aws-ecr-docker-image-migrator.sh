#!/bin/sh

CUSTOMER_ID=$1
SOURCE_REPOSITORY=$2
TARGET_REPOSITORY=$3
ECR_URL=${CUSTOMER_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com

TMP_FILE=/tmp/imagePushedAt ; > ${TMP_FILE}

eval $(aws ecr get-login --no-include-email)

imageDigests=$(aws ecr list-images --repository-name ${SOURCE_REPOSITORY} | jq -r '.imageIds[].imageDigest' | sort -u)

echo "${imageDigests}" | while read digest; do
    imagePushedAt=$(aws ecr describe-images --repository-name ${SOURCE_REPOSITORY} --image-ids imageDigest=${digest} | jq -r '.imageDetails[].imagePushedAt')
    echo "${imagePushedAt},${digest}" >> ${TMP_FILE}
done

cat ${TMP_FILE} | sort | while read image; do
    digest=$(echo ${image} | cut -d',' -f2)
  
    sourceImage=${SOURCE_REPOSITORY}@${digest}
    targetImage=${TARGET_REPOSITORY}@${digest}

    echo "=> Copying from source: '${sourceImage}' to target: '${targetImage}'"

    docker pull ${ECR_URL}/${sourceImage}
    
    # as we cannot push a digest reference this is a workaround
    # 1. add 'unknown' tag to the image
    docker tag ${ECR_URL}/${sourceImage} ${ECR_URL}/${TARGET_REPOSITORY}:unknown

    # 2. push image with 'unknown' tag
    docker push ${ECR_URL}/${TARGET_REPOSITORY}:unknown
    
    # 3. check if source image has any imageTags; if yes add them to the target images
    tags=$(aws ecr describe-images --repository-name ${SOURCE_REPOSITORY} --image-ids imageDigest=${digest} 2>/dev/null | jq -r '.imageDetails[].imageTags[]' 2>/dev/null)
    if [[ "${tags}" ]]; then 
        imageManifest=$(aws ecr batch-get-image --repository-name ${TARGET_REPOSITORY} \
                                                --image-ids imageTag=unknown \
                                                --query 'images[].imageManifest' \
                                                --output text)
        echo "${tags}" | while read tag; do
            aws ecr put-image --repository-name ${TARGET_REPOSITORY} --image-tag ${tag} --image-manifest "${imageManifest}"
        done
    fi

    # 4. check number of tags; if greater than 1 then remove 'unknown' tag, otherwise keep it
    # if image has only one tag you cannot just remove it and if you do that it will remove the image
    # workaround for this is to move tag to another image which has more than 1 tag and then remove it
    numberOfTags=$(aws ecr describe-images --repository-name ${TARGET_REPOSITORY} --image-ids imageTag=unknown 2>/dev/null | jq -r '.imageDetails[].imageTags | length')
    if [[ ${numberOfTags} -gt 1 ]]; then
        aws ecr batch-delete-image --repository-name ${TARGET_REPOSITORY} --image-ids imageTag=unknown
    fi
    docker rmi ${ECR_URL}/${sourceImage} -f &>/dev/null
done

docker rmi ${ECR_URL}/${TARGET_REPOSITORY}:unknown -f &>/dev/null
