package main

import (
	"reflect"
	"sync/atomic"
	"testing"
)

type suspendHiddenFixture struct {
	initOk atomic.Bool
	device suspendHiddenDevice
}

type suspendHiddenDevice struct{ downs atomic.Int32 }

func (d *suspendHiddenDevice) Down() { d.downs.Add(1) }

func TestAccessibleReflectValueAllowsMethodsOnUnexportedFields(t *testing.T) {
	fixture := &suspendHiddenFixture{device: suspendHiddenDevice{}}
	fixture.initOk.Store(true)

	initField := findFieldByName(reflect.ValueOf(fixture), "initOk")
	initValue := makeReflectValueAccessible(initField)
	loadMethod := findCallableMethod(initValue, "Load")
	if !loadMethod.IsValid() {
		t.Fatal("atomic Load method was not found")
	}
	loaded := loadMethod.Call(nil)
	if len(loaded) != 1 || !loaded[0].Bool() {
		t.Fatal("atomic readiness could not be read through an unexported field")
	}

	deviceField := findFieldByName(reflect.ValueOf(fixture), "device")
	deviceValue := makeReflectValueAccessible(deviceField)
	downMethod := findCallableMethod(deviceValue, "Down")
	if !downMethod.IsValid() {
		t.Fatal("device Down method was not found")
	}
	downMethod.Call(nil)
	if got := fixture.device.downs.Load(); got != 1 {
		t.Fatalf("Down calls = %d, want 1", got)
	}
}

func TestAccessibleReflectValueRejectsUnaddressableHiddenField(t *testing.T) {
	fixture := suspendHiddenFixture{}
	field := findFieldByName(reflect.ValueOf(fixture), "initOk")
	if got := makeReflectValueAccessible(field); got.IsValid() {
		t.Fatal("unaddressable unexported field must fail closed")
	}
}
