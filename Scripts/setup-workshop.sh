# Set up environment variables
echo 'ELASTICSEARCH_USERNAME=elastic' >> /root/.env
#echo -n 'ELASTICSEARCH_PASSWORD=' >> /root/.env
kubectl get secret elasticsearch-es-elastic-user -n default -o go-template='ELASTICSEARCH_PASSWORD={{.data.elastic | base64decode}}' >> /root/.env
echo '' >> /root/.env
echo 'ELASTICSEARCH_URL="http://localhost:30920"' >> /root/.env
echo 'KIBANA_URL="http://localhost:30002"' >> /root/.env
echo 'BUILD_NUMBER="10"' >> /root/.env
echo 'ELASTIC_VERSION="9.1.0"' >> /root/.env
echo 'ELASTIC_APM_SERVER_URL=http://apm.default.svc:8200' >> /root/.env
echo 'ELASTIC_APM_SECRET_TOKEN=pkcQROVMCzYypqXs0b' >> /root/.env

# Set up environment
export $(cat /root/.env | xargs)

BASE64=$(echo -n "elastic:${ELASTICSEARCH_PASSWORD}" | base64)
KIBANA_URL_WITHOUT_PROTOCOL=$(echo $KIBANA_URL | sed -e 's#http[s]\?://##g')

# Add sdg user with superuser role
curl -X POST "http://localhost:30920/_security/user/fraud" -H "Content-Type: application/json" -u "elastic:${ELASTICSEARCH_PASSWORD}" -d '{
  "password" : "hunter",
  "roles" : [ "superuser" ],
  "full_name" : "Fraud Hunter",
  "email" : "sdg@elastic-pahlsoft.com"
}'


# Install LLM Connector
bash /opt/workshops/elastic-llm.sh -k false -m claude-sonnet-4 -d true

echo
echo "AI Assistant Connector configured as OpenAI"
echo

# Use Security view
bash /opt/workshops/elastic-view.sh -v classic

echo
echo "Default Kibana view applied"
echo

# Enable workflows
curl -X POST "http://localhost:30002/api/kibana/settings" -H "Content-Type: application/json" -H "kbn-xsrf: true" -H "x-elastic-internal-origin: featureflag" -u "fraud:hunter"  -d '{
    "changes": {
      "workflows:ui:enabled": true
    }
  }'

# Create medicaid-provider-spending--fraud-workshop data views
curl -X POST "http://localhost:30002/api/saved_objects/index-pattern/fraud-medicaid-workshop" -H "Content-Type: application/json" -H "kbn-xsrf: true" -u "fraud:hunter" -d '{ "attributes": { "title": "fraud-medicaid*", "name": "Fraud Workshop", "timeFieldName": "CLAIM_FROM_MONTH", "id": "fraud-medicaid-workshop"  }}'  
  
# Create ML jobs
curl -X PUT "http://localhost:30920/_ml/anomaly_detectors/medicaid-provider-population-analysis" -H "Content-Type: application/json" -u "fraud:hunter" -d @/root/medicaid-provider-spending--fraud-workshop/ML/medicaid-provider-population-analysis.json
curl -X PUT "http://localhost:30920/_ml/anomaly_detectors/medicaid-advanced-peer-behavioral-profiling" -H "Content-Type: application/json" -u "fraud:hunter" -d @/root/medicaid-provider-spending--fraud-workshop/ML/medicaid-advanced-peer-behavioral-profiling.json
curl -X PUT "http://localhost:30920/_ml/anomaly_detectors/medicaid-rare-billing-patterns" -H "Content-Type: application/json" -u "fraud:hunter" -d @/root/medicaid-provider-spending--fraud-workshop/ML/medicaid-rare-billing-patterns.json

# Create the ML job datafeeds
curl -X PUT "http://localhost:30920/_ml/datafeeds/datafeed-medicaid-provider-population-analysis" -H "Content-Type: application/json" -u "fraud:hunter" -d @/root/medicaid-provider-spending--fraud-workshop/ML/datafeed-medicaid-provider-population-analysis.json
curl -X PUT "http://localhost:30920/_ml/datafeeds/datafeed-medicaid-are-billing-patterns" -H "Content-Type: application/json" -u "fraud:hunter" -d @/root/medicaid-provider-spending--fraud-workshop/ML/datafeed-medicaid-rare-billing-patterns.json
curl -X PUT "http://localhost:30920/_ml/datafeeds/datafeed-medicaid-advanced-peer-behavioral-profiling" -H "Content-Type: application/json" -u "fraud:hunter" -d @/root/medicaid-provider-spending--fraud-workshop/ML/datafeed-medicaid-advanced-peer-behavioral-profiling.json

clear

echo
echo
echo
echo "You are now ready to begin the workshop."
