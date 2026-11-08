package llm

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

type TokenProvider struct {
	TenantID     string
	ClientID     string
	ClientSecret string
	cachedToken  string
	expiresAt    int64
	mutex        sync.RWMutex
}

type oauthTokenResponse struct {
	AccessToken string `json:"access_token"`
	ExpiresIn   int    `json:"expires_in"`
	TokenType   string `json:"token_type"`
}

func NewAzureTokenProvider() *TokenProvider {
	tenantID := os.Getenv("AZURE_TENANT_ID")
	if tenantID == "" {
		tenantID = "a84d585b-574d-4eb7-be2a-eaea93ef7b1f"
	}

	return &TokenProvider{
		TenantID:     tenantID,
		ClientID:     os.Getenv("AZURE_CLIENT_ID"),
		ClientSecret: os.Getenv("AZURE_CLIENT_SECRET"),
	}
}

func (tp *TokenProvider) GetBearerToken() (string, error) {
	now := time.Now().Unix()

	tp.mutex.RLock()
	if tp.cachedToken != "" && now < tp.expiresAt {
		token := tp.cachedToken
		tp.mutex.RUnlock()
		return token, nil
	}
	tp.mutex.RUnlock()

	tp.mutex.Lock()
	defer tp.mutex.Unlock()

	// Double check after acquiring write lock
	if tp.cachedToken != "" && time.Now().Unix() < tp.expiresAt {
		return tp.cachedToken, nil
	}

	token, expiresAt, err := tp.fetchOAuthToken()
	if err != nil {
		return "", err
	}

	tp.cachedToken = token
	tp.expiresAt = expiresAt
	return token, nil
}

func (tp *TokenProvider) Invalidate() {
	tp.mutex.Lock()
	defer tp.mutex.Unlock()
	tp.cachedToken = ""
	tp.expiresAt = 0
}

func (tp *TokenProvider) fetchOAuthToken() (string, int64, error) {
	oauthURL := fmt.Sprintf("https://login.microsoftonline.us/%s/oauth2/v2.0/token", tp.TenantID)

	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("client_id", tp.ClientID)
	form.Set("client_secret", tp.ClientSecret)
	form.Set("scope", "https://cognitiveservices.azure.us/.default")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.PostForm(oauthURL, form)
	if err != nil {
		return "", 0, fmt.Errorf("OAuth token request failed: %w", err)
	}
	defer resp.Body.Close()

	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", 0, fmt.Errorf("failed to read OAuth response body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", 0, fmt.Errorf("OAuth server returned error %d: %s", resp.StatusCode, string(bodyBytes))
	}

	var payload oauthTokenResponse
	if err := json.Unmarshal(bodyBytes, &payload); err != nil {
		return "", 0, fmt.Errorf("failed to parse OAuth token response: %w", err)
	}

	if payload.AccessToken == "" {
		return "", 0, fmt.Errorf("OAuth response missing access_token")
	}

	expiresIn := payload.ExpiresIn
	if expiresIn <= 0 {
		expiresIn = 3600
	}

	// Refresh 60 seconds early
	expiresAt := time.Now().Unix() + int64(expiresIn) - 60
	return payload.AccessToken, expiresAt, nil
}

// GetAzureConfig returns endpoint URL, deployment model name, and segment/env settings.
func GetAzureConfig() (endpointURL string, deploymentName string) {
	segment := os.Getenv("SEGMENT")
	if segment == "" {
		segment = "ent"
	}
	environment := os.Getenv("ENVIRONMENT")
	if environment == "" {
		environment = "dev"
	}

	deploymentName = os.Getenv("AZURE_DEPLOYMENT_NAME")
	if deploymentName == "" {
		deploymentName = fmt.Sprintf("gpt-5.1-advanced-analytics-advanced-analytics-%s-%s", segment, environment)
	}

	baseURL := os.Getenv("AZURE_OPENAI_ENDPOINT")
	if baseURL == "" {
		baseURL = os.Getenv("AZURE_OPENAI_BASE")
	}
	if baseURL == "" {
		baseURL = fmt.Sprintf("https://aisvc-foundry-ai-service-%s-%s.cognitiveservices.azure.us", segment, environment)
	}

	baseURL = strings.TrimSuffix(baseURL, "/")
	if strings.HasSuffix(baseURL, "/openai/v1/chat/completions") {
		endpointURL = baseURL
	} else if strings.HasSuffix(baseURL, "/openai/v1") {
		endpointURL = fmt.Sprintf("%s/chat/completions", baseURL)
	} else {
		endpointURL = fmt.Sprintf("%s/openai/v1/chat/completions", baseURL)
	}

	return endpointURL, deploymentName
}
