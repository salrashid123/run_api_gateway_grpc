
## GCP API Gateway with gRPC

Simple gRPC client/server for GCP API Gateway and Cloud Run:

`client` -> `(gRPC+auth)` -> `APIGateway` -> `(gRPC+auth)` -> `Cloud Run API Server`

other references:

- [gRPC Authentication with Cloud Run](https://github.com/salrashid123/cloud_run_grpc_auth)
- [gRPC Authentication with Google OpenID Connect tokens](https://github.com/salrashid123/grpc_google_id_tokens)
- [Endpoints v2: Configuring a gRPC service](https://cloud.google.com/endpoints/docs/grpc/grpc-service-config)
- [Google API Gateway](https://cloud.google.com/api-gateway/docs)

### Setup

Set environment variables

```bash
    export PROJECT_ID=`gcloud config get-value core/project`
    export PROJECT_NUMBER=`gcloud projects describe $PROJECT_ID --format='value(projectNumber)'`

    gcloud config set run/region us-central1
    gcloud config set run/platform managed
```

Optionally recompile proto file:

```bash
/usr/local/bin/protoc -I src/ \
 --include_imports --include_source_info \
 --descriptor_set_out=src/echo/echo.proto.pb \
 --go_out=plugins=grpc:src/ src/echo/echo.proto
```

### Build and deploy backend API server

Build & push backend server image

```bash
    docker build -t gcr.io/$PROJECT_ID/apiserver-grpc -f Dockerfile.server .
    docker push gcr.io/$PROJECT_ID/apiserver-grpc
```

```bash
gcloud run deploy apiserver-grpc \
  --image gcr.io/$PROJECT_ID/apiserver-grpc --no-allow-unauthenticated  -q


## the following enables a secondary application layer check for the authorization header and audience
## normally it isn't necessary to do this since this is done on the perimeter via GCP IAM
## but its my repo and i can do what i want
export RUN_URL=`gcloud run services describe apiserver-grpc --format='value(status.url)'`
echo $RUN_URL

gcloud run deploy apiserver-grpc \
  --image gcr.io/$PROJECT_ID/apiserver-grpc --no-allow-unauthenticated \
  --args="--validateToken=true,--targetAudience=$RUN_URL"  -q  
```

Test direct access to backend.  

Now create a service account that will act as the 'client' to the gateway

```bash
gcloud iam service-accounts create gateway-client-sa  --display-name "Service Account for API-Gateway Client" 
gcloud iam service-accounts keys create api-client-sa.json --iam-account=gateway-client-sa@$PROJECT_ID.iam.gserviceaccount.com

export AUDIENCE=`gcloud beta run services describe apiserver-grpc --format="value(status.url)"`
export ADDRESS=`echo $AUDIENCE |  awk -F[/:] '{print $4}'`
echo $AUDIENCE
echo $ADDRESS

## allow this client to temp access the backend
## this step is just to test if the service is setup correctly
gcloud run services add-iam-policy-binding apiserver-grpc \
      --region us-central1  --platform=managed  \
      --member=serviceAccount:gateway-client-sa@$PROJECT_ID.iam.gserviceaccount.com \
      --role=roles/run.invoker

# wait about a min

$ go run src/grpc_client.go --address $ADDRESS:443 \
   --audience=$AUDIENCE \
   --servername $ADDRESS \
   --serviceAccount=api-client-sa.json

## if the step above works, +_revoke_ direct access (gateway-client-sa will eventually contact the gateway only)
gcloud run services remove-iam-policy-binding apiserver-grpc \
      --region us-central1  --platform=managed  \
      --member=serviceAccount:gateway-client-sa@$PROJECT_ID.iam.gserviceaccount.com \
      --role=roles/run.invoker
```

### Deploy Gateway

In the following step, we will create a service account that will eventually be used the "Gateways" Service Account

```bash
gcloud iam service-accounts create gateway-sa  --display-name "Service Account for API-Gateway" 

gcloud run services add-iam-policy-binding apiserver-grpc \
      --region us-central1  --platform=managed  \
      --member=serviceAccount:gateway-sa@$PROJECT_ID.iam.gserviceaccount.com \
      --role=roles/run.invoker
```

Now create the API 

```bash
gcloud beta api-gateway apis create grpc-api-1

gcloud beta api-gateway apis list
export MANAGED_SERVICE=`gcloud beta api-gateway apis describe grpc-api-1 --format="value(managedService)"`
echo $MANAGED_SERVICE
echo $AUDIENCE
echo $ADDRESS

gcloud endpoints configs list --service $MANAGED_SERVICE
```

Create the API.  

(This step is manual using curl until gcloud cli is updated)

```bash
export API_ID=grpc-api-1
export API_CONFIG_ID=grpc-config-1
export SOURCE_FILE=api_config.yaml
export PROTO_FILE=src/echo/echo.proto.pb


echo $MANAGED_SERVICE
echo $AUDIENCE
echo $ADDRESS

envsubst < "api_config.yaml.tmpl" > "api_config.yaml"

curl -X POST -H "Content-type: application/json"  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    https://apigateway.googleapis.com/v1beta/projects/${PROJECT_ID}/locations/global/apis/${API_ID}/configs?api_config_id=${API_CONFIG_ID} \
       -d '{"gateway_service_account":"gateway-sa@'$PROJECT_ID'.iam.gserviceaccount.com", "managed_service_configs":[{"path":"api_config.yaml","contents":"'$(base64 -i -w0 ${SOURCE_FILE})'"} ], "grpc_services": {"file_descriptor_set": {"path":"src/echo/echo.proto.pb","contents":"'$(base64 -i -w0 ${PROTO_FILE})'"} } }'

# wait about a 3 or 4 mins until its ACTIVE
$  gcloud beta api-gateway api-configs list
CONFIG_ID      API_ID      DISPLAY_NAME   SERVICE_CONFIG_ID            STATE   CREATE_TIME
grpc-config-1  grpc-api-1  grpc-config-1  grpc-config-1-05zcbixuegzsp  ACTIVE  2020-12-18T15:38:30
```

Create the gateway

```bash
gcloud beta api-gateway gateways create grpc-gateway-1 --location us-central-1 --api grpc-api-1 --api-config=grpc-config-1
export GATEWAY_HOST=`gcloud beta api-gateway gateways describe grpc-gateway-1 --location us-central1 --format='value(defaultHostname)'`
echo $GATEWAY_HOST
```


## Finally invoke the API Gateway using the client

```bash
 go run src/grpc_client.go --address $GATEWAY_HOST:443 \
   --audience=grpcs://grpc-gateway-1 \
   --servername $GATEWAY_HOST \
   --serviceAccount=api-client-sa.json     
```

NOTE: the api gateway allows any Google Issued OIDC token through

For other options, see [Authentication Rules (google.api.AuthProvider)](https://cloud.google.com/endpoints/docs/grpc-service-config/reference/rpc/google.api#authprovider)

```yaml
authentication:
  providers:
  - id: google_id_token
    authorization_url: ''
    audiences: 'grpcs://grpc-gateway-1'
    issuer: 'https://accounts.google.com'
    jwks_uri: 'https://www.googleapis.com/oauth2/v1/certs'
  rules:
  - selector: "*"
    requirements:
      - provider_id: google_id_token
```