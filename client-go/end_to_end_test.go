package client_test

import (
	"context"
	"fmt"
	"net/http"
	"testing"

	"codeberg.org/adamcstephens/sower/client-go"
)

// custom HTTP client
var hc = http.Client{}

func TestClient_RawRequest(t *testing.T) {

	// with a raw http.Response
	c, err := client.NewClient("http://localhost:7150", client.WithHTTPClient(&hc))
	if err != nil {
		t.Fatal(err)
	}

	resp, err := c.ListSeeds(context.TODO(), &client.ListSeedsParams{})
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("Expected HTTP 200 but received %d", resp.StatusCode)
	}
}

func TestClient_SeedList(t *testing.T) {
	// or to get a struct with the parsed response body
	c, err := client.NewClientWithResponses("http://localhost:7150", client.WithHTTPClient(&hc))
	if err != nil {
		t.Fatal(err)
	}

	resp, err := c.ListSeedsWithResponse(context.TODO(), &client.ListSeedsParams{})
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode() != http.StatusOK {
		t.Fatalf("Expected HTTP 200 but received %d", resp.StatusCode())
	}

	fmt.Printf("resp.JSON200: %v\n", resp.JSON200)
}
