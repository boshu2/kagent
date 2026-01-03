/*
Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"os"
	"strings"

	"github.com/kagent-dev/kagent/go/internal/httpserver/auth"
	"github.com/kagent-dev/kagent/go/pkg/app"
	pkgauth "github.com/kagent-dev/kagent/go/pkg/auth"

	// Import all Kubernetes client auth plugins (e.g. Azure, GCP, OIDC, etc.)
	// to ensure that exec-entrypoint and run can make use of them.
	_ "k8s.io/client-go/plugin/pkg/client/auth"

	ctrl "sigs.k8s.io/controller-runtime"
)

var setupLog = ctrl.Log.WithName("setup")

// createAuthenticator creates the appropriate authenticator based on environment configuration.
// Returns OAuth2Authenticator when AUTH_OAUTH2_ENABLED=true, otherwise UnsecureAuthenticator.
func createAuthenticator() (pkgauth.AuthProvider, error) {
	if os.Getenv("AUTH_OAUTH2_ENABLED") == "true" {
		issuerURL := os.Getenv("AUTH_OAUTH2_ISSUER_URL")
		clientID := os.Getenv("AUTH_OAUTH2_CLIENT_ID")

		if issuerURL == "" || clientID == "" {
			setupLog.Info("OAuth2 enabled but issuer URL or client ID not set, falling back to unsecure auth")
			return &auth.UnsecureAuthenticator{}, nil
		}

		config := auth.OAuth2Config{
			IssuerURL:            issuerURL,
			ClientID:             clientID,
			Audience:             os.Getenv("AUTH_OAUTH2_AUDIENCE"),
			UserIDClaim:          getEnvOrDefault("AUTH_OAUTH2_USER_ID_CLAIM", "sub"),
			RolesClaim:           getEnvOrDefault("AUTH_OAUTH2_ROLES_CLAIM", "roles"),
			SkipIssuerValidation: os.Getenv("AUTH_OAUTH2_SKIP_ISSUER_VALIDATION") == "true",
			SkipExpiryValidation: os.Getenv("AUTH_OAUTH2_SKIP_EXPIRY_VALIDATION") == "true",
		}

		// Parse required scopes if provided
		if scopes := os.Getenv("AUTH_OAUTH2_REQUIRED_SCOPES"); scopes != "" {
			config.RequiredScopes = strings.Split(scopes, ",")
		}

		setupLog.Info("Initializing OAuth2 authenticator",
			"issuerURL", issuerURL,
			"clientID", clientID,
			"skipIssuerValidation", config.SkipIssuerValidation)

		authenticator, err := auth.NewOAuth2Authenticator(config)
		if err != nil {
			return nil, err
		}
		return authenticator, nil
	}

	setupLog.Info("Using unsecure authenticator (no authentication)")
	return &auth.UnsecureAuthenticator{}, nil
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

//nolint:gocyclo
func main() {
	authorizer := &auth.NoopAuthorizer{}
	authenticator, err := createAuthenticator()
	if err != nil {
		setupLog.Error(err, "Failed to create authenticator")
		os.Exit(1)
	}

	app.Start(func(bootstrap app.BootstrapConfig) (*app.ExtensionConfig, error) {
		return &app.ExtensionConfig{
			Authenticator:    authenticator,
			Authorizer:       authorizer,
			AgentPlugins:     nil,
			MCPServerPlugins: nil,
		}, nil
	})
}
