package llm

import (
	"os"
	"testing"
)

func TestGetAzureConfig(t *testing.T) {
	os.Setenv("SEGMENT", "ent")
	os.Setenv("ENVIRONMENT", "dev")
	os.Unsetenv("AZURE_DEPLOYMENT_NAME")
	os.Unsetenv("AZURE_OPENAI_BASE")

	endpoint, deployment := GetAzureConfig()

	expectedEndpoint := "https://aisvc-foundry-ai-service-ent-dev.openai.azure.us/openai/v1/chat/completions"
	expectedDeployment := "gpt-5.1-advanced-analytics-advanced-analytics-ent-dev"

	if endpoint != expectedEndpoint {
		t.Errorf("Expected endpoint '%s', got '%s'", expectedEndpoint, endpoint)
	}

	if deployment != expectedDeployment {
		t.Errorf("Expected deployment '%s', got '%s'", expectedDeployment, deployment)
	}
}

func TestGetAzureConfigOverride(t *testing.T) {
	os.Setenv("AZURE_DEPLOYMENT_NAME", "custom-deployment")
	os.Setenv("AZURE_OPENAI_BASE", "https://custom-azure.openai.azure.us")

	endpoint, deployment := GetAzureConfig()

	expectedEndpoint := "https://custom-azure.openai.azure.us/openai/v1/chat/completions"
	expectedDeployment := "custom-deployment"

	if endpoint != expectedEndpoint {
		t.Errorf("Expected endpoint '%s', got '%s'", expectedEndpoint, endpoint)
	}

	if deployment != expectedDeployment {
		t.Errorf("Expected deployment '%s', got '%s'", expectedDeployment, deployment)
	}
}
