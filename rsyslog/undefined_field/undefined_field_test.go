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

func setup(t *testing.T, cfg undefinedConfig) error {
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
	testcfg := undefinedConfig{
		Debug:                   true,
		MergeJSONLog:            true,
		UseUndefined:            true,
		UndefinedToString:       false,
		DefaultKeepFields:       "method,statusCode,type,@timestamp,req,res,CONTAINER_NAME,CONTAINER_ID_FULL",
		ExtraKeepFields:         "undefined4,undefined5,empty1,undefined3",
		UndefinedName:           "undefined",
		KeepEmptyFields:         "undefined4,undefined5,empty1,undefined3",
		UndefinedDotReplaceChar: "UNUSED",
		UndefinedMaxNumFields:   -1,
	}
	err := setup(t, testcfg)
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
	origMap := make(map[string]interface{})
	if err := json.Unmarshal([]byte(inputString), &origMap); err != nil {
		t.Errorf("json.Unmarshal failed for inputString [%v]: %v", inputString, err)
	}
	changed := processUndefinedAndEmpty(inputMap, true, true)
	if !changed {
		t.Errorf("Expected changes not performed on the input")
	}
	outputBytes, _ := json.Marshal(inputMap)
	t.Logf("outputBytes [%s]", outputBytes)
	fieldlist := []string{"@timestamp", "empty1", "undefined3", "undefined4", "undefined5"}
	if err = checkFieldsEqual(t, origMap, inputMap, fieldlist); err != nil {
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
	if err = checkFieldsEqual(t, undefinedMap, inputMap, fieldlist); err != nil {
		t.Error(err)
	}
}

func TestUndefinedMaxNumFields(t *testing.T) {
	cfg = undefinedConfig{
		Debug:                   true,
		MergeJSONLog:            true,
		UseUndefined:            true,
		UndefinedToString:       false,
		DefaultKeepFields:       "method,statusCode,type,@timestamp,req,res,CONTAINER_NAME,CONTAINER_ID_FULL",
		ExtraKeepFields:         "undefined4,undefined5,empty1,undefined3",
		UndefinedName:           "undefined",
		KeepEmptyFields:         "undefined4,undefined5,empty1,undefined3",
		UndefinedDotReplaceChar: "UNUSED",
		// the test should have 5 undefined fields - if UndefinedMaxNumFields == number of undefined fields - 1
		// this allows us to check for off-by-one errors as well
		UndefinedMaxNumFields: 4,
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
	origMap := make(map[string]interface{})
	if err := json.Unmarshal([]byte(inputString), &origMap); err != nil {
		t.Errorf("json.Unmarshal failed for inputString [%v]: %v", inputString, err)
	}
	expectedUndefString := `{"undefined.6":"undefined6","undefined1":"undefined1","undefined11":1111,"undefined12":true,"undefined2":{"":"","undefined2":"undefined2","undefined22":2222,"undefined23":false}}`
	undefString, undefMap, _ := processUndefinedAndMaxNumFields(inputMap)
	outputBytes, _ := json.Marshal(inputMap)
	t.Logf("outputBytes [%s] undefString [%s] undefMap [%v]", outputBytes, undefString, undefMap)
	if undefMap != nil {
		t.Errorf("undefMap should be nil but has value %v", undefMap)
	}
	fieldlist := []string{"@timestamp", "empty1", "undefined3", "undefined4", "undefined5"}
	if err = checkFieldsEqual(t, origMap, inputMap, fieldlist); err != nil {
		t.Error(err)
	}
	if undefMap != nil {
		t.Error("The undefMap is supposed to be nil")
	}
	// convert undefString back to map for comparison purposes
	undefMap = make(map[string]interface{})
	if err = json.Unmarshal([]byte(undefString), &undefMap); err != nil {
		t.Errorf("Could not convert undefString [%s] back to map: %v", undefString, err)
	}
	expectedUndefMap := make(map[string]interface{})
	if err = json.Unmarshal([]byte(expectedUndefString), &expectedUndefMap); err != nil {
		t.Errorf("Could not convert expectedUndefString [%s] back to map: %v", expectedUndefString, err)
	}
	fieldlist = []string{"undefined1", "undefined11", "undefined12", "undefined2", "undefined.6"}
	if err = checkFieldsEqual(t, expectedUndefMap, undefMap, fieldlist); err != nil {
		t.Error(err)
	}
}
