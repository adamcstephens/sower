package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
)

type seed struct {
	Id      int
	Name    string
	Type    string
	OutPath string `json:"out_path"`
}

func main() {
	resp, err := http.Get("https://sower.dev/api/seeds/latest?name=blank&type=nixos")
	if err != nil {
		log.Fatalf("failed to fetch seed: %v", err)
	} else if resp.StatusCode != 200 {
		log.Fatalf("failed to fetch seed: %v", resp.Status)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Fatalf("failed to fetch seed: %v", err)
		os.Exit(1)
	}

	seed := seed{}
	err = json.Unmarshal(body, &seed)
	if err != nil {
		log.Fatalf("failed to fetch seed: %v", err)
		os.Exit(1)
	}

	fmt.Println(seed)
}
