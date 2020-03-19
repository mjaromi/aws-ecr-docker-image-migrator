# aws-ecr-docker-image-migrator

```bash
export AWS_DEFAULT_REGION=
export AWS_ACCESS_KEY_ID=
export AWS_SECRET_ACCESS_KEY=

CUSTOMER_ID=
SOURCE_REPOSITORY=
TARGET_REPOSITORY=
ECR_URL=${CUSTOMER_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com

TMP_FILE=/tmp/imagePushedAt ; > ${TMP_FILE}

eval $(aws ecr get-login)
availableTags=$(aws ecr list-images --repository-name ${SOURCE_REPOSITORY} | jq -r '.imageIds[].imageTag')

echo "${availableTags}" | while read tag; do
  aws ecr describe-images --repository-name ${SOURCE_REPOSITORY} --image-ids imageTag=${tag} | jq -r '.imageDetails[].imagePushedAt' >> ${TMP_FILE}
done

echo "${availableTags}" | while read tag; do
  docker images -q | sort -u | while read image; do 
    echo "=> Remove image: ${image}"
    docker rmi ${image} -f &>/dev/null
  done
  
  sourceImage=${SOURCE_REPOSITORY}:${tag}
  targetImage=${TARGET_REPOSITORY}:${tag}
  
  echo "=> Migrate sourceImage: ${sourceImage}"
  
  docker pull ${ECR_URL}/${sourceImage}
  
  docker tag ${ECR_URL}/${sourceImage} ${ECR_URL}/${targetImage}
  
  docker push ${ECR_URL}/${targetImage}
done
```
