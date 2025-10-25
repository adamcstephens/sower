package main

import (
	"strings"
	"testing"

	"codeberg.org/adamcstephens/sower/client-go"
)

func TestTagParsing(t *testing.T) {
	tests := []struct {
		name        string
		input       []string
		wantTags    []client.SeedTag
		wantErr     bool
		errContains string
	}{
		{
			name:  "single tag",
			input: []string{"environment=production"},
			wantTags: []client.SeedTag{
				{Key: "environment", Value: "production"},
			},
			wantErr: false,
		},
		{
			name:  "multiple tags",
			input: []string{"environment=production", "version=1.2.3", "region=us-west-2"},
			wantTags: []client.SeedTag{
				{Key: "environment", Value: "production"},
				{Key: "version", Value: "1.2.3"},
				{Key: "region", Value: "us-west-2"},
			},
			wantErr: false,
		},
		{
			name:     "empty tags",
			input:    []string{},
			wantTags: []client.SeedTag{},
			wantErr:  false,
		},
		{
			name:        "invalid tag format - no equals",
			input:       []string{"invalidtag"},
			wantTags:    nil,
			wantErr:     true,
			errContains: "Invalid tag format",
		},
		{
			name:        "invalid tag format - multiple equals",
			input:       []string{"key=value=extra"},
			wantTags:    []client.SeedTag{{Key: "key", Value: "value=extra"}},
			wantErr:     false,
			errContains: "",
		},
		{
			name:  "tag with empty value",
			input: []string{"key="},
			wantTags: []client.SeedTag{
				{Key: "key", Value: ""},
			},
			wantErr: false,
		},
		{
			name:        "tag with empty key",
			input:       []string{"=value"},
			wantTags:    []client.SeedTag{{Key: "", Value: "value"}},
			wantErr:     false,
			errContains: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var tags []client.SeedTag
			var err error

			for _, tagStr := range tt.input {
				parts := strings.SplitN(tagStr, "=", 2)
				if len(parts) != 2 {
					err = &TagParseError{Tag: tagStr}
					break
				}
				tags = append(tags, client.SeedTag{
					Key:   parts[0],
					Value: parts[1],
				})
			}

			if tt.wantErr {
				if err == nil {
					t.Errorf("expected error but got none")
				}
				return
			}

			if err != nil {
				t.Errorf("unexpected error: %v", err)
				return
			}

			if len(tags) != len(tt.wantTags) {
				t.Errorf("got %d tags, want %d", len(tags), len(tt.wantTags))
				return
			}

			for i, tag := range tags {
				if tag.Key != tt.wantTags[i].Key || tag.Value != tt.wantTags[i].Value {
					t.Errorf("tag[%d]: got {Key: %q, Value: %q}, want {Key: %q, Value: %q}",
						i, tag.Key, tag.Value, tt.wantTags[i].Key, tt.wantTags[i].Value)
				}
			}
		})
	}
}

type TagParseError struct {
	Tag string
}

func (e *TagParseError) Error() string {
	return "Invalid tag format. Expected key=value"
}
