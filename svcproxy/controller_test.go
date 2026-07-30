package main

import (
	"slices"
	"testing"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func ptr[T any](v T) *T { return &v }

func TestDiffListeners(t *testing.T) {
	kAPI := proxyKey{ip: "10.43.0.1", port: 443, proto: "TCP"}
	kDNS := proxyKey{ip: "10.43.0.10", port: 53, proto: "UDP"}
	kWeb := proxyKey{ip: "10.43.7.7", port: 80, proto: "TCP"}
	kOld := proxyKey{ip: "10.43.9.9", port: 5432, proto: "TCP"}

	running := map[proxyKey][]string{
		kAPI: {"10.0.0.1:6443"},
		kDNS: {"10.42.0.3:53"},
		kOld: {"10.42.0.8:5432"},
	}
	desired := map[proxyKey][]string{
		kAPI: {"10.0.0.1:6443"},  // unchanged: no action
		kDNS: {"10.42.0.4:53"},   // endpoints changed: swap in place, no restart
		kWeb: {"10.42.0.9:8080"}, // new: start
		// kOld gone: stop
	}
	start, stop, update := diffListeners(running, desired)
	if !slices.Equal(start, []proxyKey{kWeb}) {
		t.Errorf("start = %v, want [%v]", start, kWeb)
	}
	if !slices.Equal(stop, []proxyKey{kOld}) {
		t.Errorf("stop = %v, want [%v]", stop, kOld)
	}
	if !slices.Equal(update, []proxyKey{kDNS}) {
		t.Errorf("update = %v, want [%v]", update, kDNS)
	}
}

func TestDiffListenersPortChangeRestarts(t *testing.T) {
	oldKey := proxyKey{ip: "10.43.7.7", port: 80, proto: "TCP"}
	newKey := proxyKey{ip: "10.43.7.7", port: 8080, proto: "TCP"}
	eps := []string{"10.42.0.9:8080"}
	start, stop, update := diffListeners(
		map[proxyKey][]string{oldKey: eps},
		map[proxyKey][]string{newKey: eps},
	)
	if !slices.Equal(start, []proxyKey{newKey}) || !slices.Equal(stop, []proxyKey{oldKey}) || len(update) != 0 {
		t.Errorf("port change: start=%v stop=%v update=%v, want start=[%v] stop=[%v] update=[]",
			start, stop, update, newKey, oldKey)
	}
}

func TestDiffListenersSteadyState(t *testing.T) {
	k := proxyKey{ip: "10.43.0.1", port: 443, proto: "TCP"}
	m := map[proxyKey][]string{k: {"10.0.0.1:6443"}}
	start, stop, update := diffListeners(m, m)
	if len(start)+len(stop)+len(update) != 0 {
		t.Errorf("steady state produced changes: start=%v stop=%v update=%v", start, stop, update)
	}
}

func slice(name string, atype discoveryv1.AddressType, ports []discoveryv1.EndpointPort, eps ...discoveryv1.Endpoint) *discoveryv1.EndpointSlice {
	return &discoveryv1.EndpointSlice{
		ObjectMeta:  metav1.ObjectMeta{Name: name, Namespace: "default"},
		AddressType: atype,
		Ports:       ports,
		Endpoints:   eps,
	}
}

func TestReadyEndpoints(t *testing.T) {
	tcp := corev1.ProtocolTCP
	httpPort := []discoveryv1.EndpointPort{{Name: ptr("http"), Port: ptr[int32](8080), Protocol: &tcp}}
	sls := []*discoveryv1.EndpointSlice{
		slice("web-1", discoveryv1.AddressTypeIPv4, httpPort,
			discoveryv1.Endpoint{Addresses: []string{"10.42.0.5"}}, // nil Ready counts as ready
			discoveryv1.Endpoint{Addresses: []string{"10.42.0.6"}, Conditions: discoveryv1.EndpointConditions{Ready: ptr(true)}},
			discoveryv1.Endpoint{Addresses: []string{"10.42.0.7"}, Conditions: discoveryv1.EndpointConditions{Ready: ptr(false)}},
		),
		slice("web-2", discoveryv1.AddressTypeIPv6, // wrong family: ignored entirely
			[]discoveryv1.EndpointPort{{Name: ptr("http"), Port: ptr[int32](8080), Protocol: &tcp}},
			discoveryv1.Endpoint{Addresses: []string{"fd00::5"}},
		),
		slice("web-3", discoveryv1.AddressTypeIPv4, httpPort, // duplicate of an existing backend
			discoveryv1.Endpoint{Addresses: []string{"10.42.0.5"}},
		),
	}
	got := readyEndpoints(sls, "http", corev1.ProtocolTCP)
	want := []string{"10.42.0.5:8080", "10.42.0.6:8080"}
	if !slices.Equal(got, want) {
		t.Errorf("readyEndpoints = %v, want %v", got, want)
	}
	if got := readyEndpoints(sls, "metrics", corev1.ProtocolTCP); len(got) != 0 {
		t.Errorf("unknown port name resolved endpoints: %v", got)
	}
	if got := readyEndpoints(sls, "http", corev1.ProtocolUDP); len(got) != 0 {
		t.Errorf("protocol mismatch resolved endpoints: %v", got)
	}
}

func TestReadyEndpointsUnnamedPort(t *testing.T) {
	tcp := corev1.ProtocolTCP
	sls := []*discoveryv1.EndpointSlice{
		slice("db-1", discoveryv1.AddressTypeIPv4,
			[]discoveryv1.EndpointPort{{Port: ptr[int32](5432), Protocol: &tcp}}, // single unnamed port
			discoveryv1.Endpoint{Addresses: []string{"10.42.0.9"}},
		),
	}
	got := readyEndpoints(sls, "", corev1.ProtocolTCP)
	if want := []string{"10.42.0.9:5432"}; !slices.Equal(got, want) {
		t.Errorf("readyEndpoints = %v, want %v", got, want)
	}
}
