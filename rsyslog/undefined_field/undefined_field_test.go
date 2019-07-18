package main

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"os"
	"testing"
)

var (
	defaultKeepFields = "method,statusCode,type,@timestamp,req,res,CONTAINER_NAME,CONTAINER_ID_FULL"
)

func setup(t *testing.T) (string, error) {
	testLogfile, err := ioutil.TempFile("", "log")
	if err != nil {
		return "", fmt.Errorf("Could not create temp log file: %v", err)
	}
	testCfgfile, err := ioutil.TempFile("", "cfg")
	if err != nil {
		os.Remove(testLogfile.Name())
		return "", fmt.Errorf("Could not create temp cfg file")
	}
	defer os.Remove(testCfgfile.Name())
	os.Setenv("LOGGING_FILE_PATH", testLogfile.Name())
	// write cfg options to testCfgfile
	cfg := UndefinedConfig{
		Debug:                      true,
		Merge_json_log:             true,
		Use_undefined:              true,
		Undefined_to_string:        false,
		Default_keep_fields:        "method,statusCode,type,@timestamp,req,res,CONTAINER_NAME,CONTAINER_ID_FULL",
		Extra_keep_fields:          "undefined4,undefined5,empty1,undefined3",
		Undefined_name:             "undefined",
		Keep_empty_fields:          "undefined4,undefined5,empty1,undefined3",
		Undefined_dot_replace_char: "UNUSED",
		Undefined_max_num_fields:   -1,
	}
	b, err := json.Marshal(cfg)
	if err != nil {
		os.Remove(testLogfile.Name())
		return "", fmt.Errorf("Could not marshal JSON config object: %v", err)
	}
	if _, err := testCfgfile.Write(b); err != nil {
		os.Remove(testLogfile.Name())
		return "", fmt.Errorf("Could not write config to %v: %v", testCfgfile.Name(), err)
	}
	os.Setenv("UNDEFINED_CONFIG", testCfgfile.Name())
	onInit()
	return testLogfile.Name(), nil
}

func TestKeepEmpty(t *testing.T) {
	testLogfilename, err := setup(t)
	defer os.Remove(testLogfilename)
	if err != nil {
		t.Errorf("test setup failed: %v", err)
	}
	inputString := `{"hostname": "hostname", "level": "info", "@timestamp": "2019-07-17T21:26:45.913217+00:00", ` +
		`"undefined1": "undefined1", "undefined11": 1111, "undefined12": true, "empty1": "", ` +
		`"undefined2": { "undefined2": "undefined2", "": "", "undefined22": 2222, "undefined23": false }, ` +
		`"undefined3": { "emptyvalue": "" }, "undefined4": {}, "undefined5": "undefined5", ` +
		`"undefined.6": "undefined6", "message": "message" }`
	inputMap := make(map[string]interface{})
	if err := json.Unmarshal([]byte(inputString), &inputMap); err != nil {
		t.Errorf("json.Unmarshal failed for inputString [%v]: %v", inputString, err)
	}
	all, replaceMe, hasUndefined := replaceDotMoveUndefined(inputMap, true)
	outputBytes, err := json.Marshal(all)
	t.Logf("outputBytes [%s] replaceMe [%v] hasUndefined [%v]", outputBytes, replaceMe, hasUndefined)
}
