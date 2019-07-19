package main

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"os"
	"reflect"
	"testing"
)

var (
	testLogfile *os.File
)

func setup(t *testing.T, cfg UndefinedConfig) error {
	var err error
	testLogfile, err = ioutil.TempFile("", "log")
	if err != nil {
		return fmt.Errorf("Could not create temp log file: %v", err)
	}
	testCfgfile, err := ioutil.TempFile("", "cfg")
	if err != nil {
		os.Remove(testLogfile.Name())
		return fmt.Errorf("Could not create temp cfg file")
	}
	defer os.Remove(testCfgfile.Name())
	os.Setenv("LOGGING_FILE_PATH", testLogfile.Name())
	// write cfg options to testCfgfile
	b, err := json.Marshal(cfg)
	if err != nil {
		os.Remove(testLogfile.Name())
		return fmt.Errorf("Could not marshal JSON config object: %v", err)
	}
	if _, err := testCfgfile.Write(b); err != nil {
		os.Remove(testLogfile.Name())
		return fmt.Errorf("Could not write config to %v: %v", testCfgfile.Name(), err)
	}
	os.Setenv("UNDEFINED_CONFIG", testCfgfile.Name())
	testLogfile.Close()
	onInit()
	return nil
}

func teardown(t *testing.T) {
	tdLogfile, err := os.Open(testLogfile.Name())
	if err != nil {
		t.Errorf("Could not open testLogfile: %v", err)
		return
	}
	fi, err := tdLogfile.Stat()
	if err != nil {
		tdLogfile.Close()
		t.Errorf("Could not seek to end of testLogfile: %v", err)
		return
	}
	_, err = tdLogfile.Seek(0, 0)
	if err != nil {
		tdLogfile.Close()
		t.Errorf("Could not rewind testLogfile: %v", err)
		return
	}
	buf := make([]byte, fi.Size())
	_, err = tdLogfile.Read(buf)
	if err != nil {
		tdLogfile.Close()
		t.Errorf("Could not read %v bytes from testLogfile: %v", fi.Size(), err)
		return
	}
	tdLogfile.Close()
	t.Logf("Test output: %s", buf)
	os.Remove(testLogfile.Name())
}

func checkFieldsEqual(t *testing.T, expected, actual map[string]interface{}, fieldlist []string) error {
	var err error
	for _, field := range fieldlist {
		if !reflect.DeepEqual(expected[field], actual[field]) {
			t.Errorf("field [%s] expected value [%v] does not match actual value [%v]",
				field, expected[field], actual[field])
			if err == nil {
				err = fmt.Errorf("one or more field values did not match")
			}
		}
	}
	return err
}

func TestKeepEmpty(t *testing.T) {
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
	err := setup(t, cfg)
	defer teardown(t)
	if err != nil {
		t.Errorf("test setup failed: %v", err)
	}
	inputString := `{"@timestamp": "2019-07-17T21:26:45.913217+00:00", ` +
		`"undefined1": "undefined1", "undefined11": 1111, "undefined12": true, "empty1": "", ` +
		`"undefined2": { "undefined2": "undefined2", "": "", "undefined22": 2222, "undefined23": false }, ` +
		`"undefined3": { "emptyvalue": "" }, "undefined4": {}, "undefined5": "undefined5", ` +
		`"undefined.6": "undefined6" }`
	inputMap := make(map[string]interface{})
	if err := json.Unmarshal([]byte(inputString), &inputMap); err != nil {
		t.Errorf("json.Unmarshal failed for inputString [%v]: %v", inputString, err)
	}
	undefined_cur_num_fields = 99999999
	outputMap, replaceMe, hasUndefined := replaceDotMoveUndefined(inputMap, true, false)
	outputBytes, err := json.Marshal(outputMap)
	t.Logf("outputBytes [%s] replaceMe [%v] hasUndefined [%v]", outputBytes, replaceMe, hasUndefined)
	fieldlist := []string{"@timestamp", "empty1", "undefined3", "undefined4", "undefined5"}
	if err = checkFieldsEqual(t, inputMap, outputMap, fieldlist); err != nil {
		t.Error(err)
	}
	var val1 float64 = 1111
	var val2 float64 = 2222
	undefined2Map := map[string]interface{}{
		"undefined2":  "undefined2",
		"undefined22": val2,
		"undefined23": false,
	}
	undefinedMap := map[string]interface{}{
		"undefined1":  "undefined1",
		"undefined11": val1,
		"undefined12": true,
		"undefined2":  undefined2Map,
		"undefined.6": "undefined6",
	}
	fieldlist = []string{"undefined1", "undefined11", "undefined12", "undefined2", "undefined.6"}
	if err = checkFieldsEqual(t, undefinedMap, outputMap["undefined"].(map[string]interface{}), fieldlist); err != nil {
		t.Error(err)
	}
}
