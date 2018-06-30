# Profiling Terraform Plans

This `profile.sh` script generates a plan with N null_resources, applies them
to state, and then plans the same file against the state generating some
profiling data.

## Results with 10000 resources

* [cpuprofile.png](https://github.com/vanstee/terraform-profiling/blob/master/cpuprofile.png)
* [memprofile.png](https://github.com/vanstee/terraform-profiling/blob/master/memprofile.png)

During a plan, a large chuck of time is spent in the `filterSingle` func. It
looks like for every node in the state graph, we loop over every resource in
the config. In each iteration the resource id string is split (causing some
allocations) and is checked to see if it's relevant to the state graph node.

If there's anyway we can directly lookup the relevant resources by generating a
string and getting the resource out of the resource map directly, that would
save a lot of time looping and would need a lot less allocations.

## Example Solution

If we remove the double for loop that runs for each graph node, and instead try
to look up resources in the map with a generated key, we can improve plan graph
diffing time by about 30%. There are some cases that this diff doesn't cover
though. We need to make sure we handle indexes, legacy state ids, and other
uncommon state ids, but I think we could at least populate the map with an
array of resources that are relevant given a resource id string.

```
diff --git a/terraform/state_filter.go b/terraform/state_filter.go
index 2dcb11b..fe71c3c 100644
--- a/terraform/state_filter.go
+++ b/terraform/state_filter.go
@@ -81,82 +81,58 @@ func (f *StateFilter) filterSingle(a *ResourceAddress) []*StateFilterResult {
 		}
 	}
 
-	// With the modules set, go through all the resources within
-	// the modules to find relevant resources.
+	n := a.String()
 	for _, m := range modules {
-		for n, r := range m.Resources {
-			// The name in the state contains valuable information. Parse.
-			key, err := ParseResourceStateKey(n)
-			if err != nil {
-				// If we get an error parsing, then just ignore it
-				// out of the state.
-				continue
-			}
+		r, ok := m.Resources[n]
+		if !ok {
+			continue
+		}
 
-			// Older states and test fixtures often don't contain the
-			// type directly on the ResourceState. We add this so StateFilter
-			// is a bit more robust.
-			if r.Type == "" {
-				r.Type = key.Type
-			}
+		key, err := ParseResourceStateKey(n)
+		if err != nil {
+			continue
+		}
+
+		// Build the address for this resource
+		addr := &ResourceAddress{
+			Path:  m.Path[1:],
+			Name:  key.Name,
+			Type:  key.Type,
+			Index: key.Index,
+		}
 
-			if f.relevant(a, r) {
-				if a.Name != "" && a.Name != key.Name {
-					// Name doesn't match
-					continue
-				}
-
-				if a.Index >= 0 && key.Index != a.Index {
-					// Index doesn't match
-					continue
-				}
-
-				if a.Name != "" && a.Name != key.Name {
-					continue
-				}
-
-				// Build the address for this resource
-				addr := &ResourceAddress{
-					Path:  m.Path[1:],
-					Name:  key.Name,
-					Type:  key.Type,
-					Index: key.Index,
-				}
-
-				// Add the resource level result
-				resourceResult := &StateFilterResult{
+		// Add the resource level result
+		resourceResult := &StateFilterResult{
+			Path:    addr.Path,
+			Address: addr.String(),
+			Value:   r,
+		}
+		if !a.InstanceTypeSet {
+			results = append(results, resourceResult)
+		}
+
+		// Add the instances
+		if r.Primary != nil {
+			addr.InstanceType = TypePrimary
+			addr.InstanceTypeSet = false
+			results = append(results, &StateFilterResult{
+				Path:    addr.Path,
+				Address: addr.String(),
+				Parent:  resourceResult,
+				Value:   r.Primary,
+			})
+		}
+
+		for _, instance := range r.Deposed {
+			if f.relevant(a, instance) {
+				addr.InstanceType = TypeDeposed
+				addr.InstanceTypeSet = true
+				results = append(results, &StateFilterResult{
 					Path:    addr.Path,
 					Address: addr.String(),
-					Value:   r,
-				}
-				if !a.InstanceTypeSet {
-					results = append(results, resourceResult)
-				}
-
-				// Add the instances
-				if r.Primary != nil {
-					addr.InstanceType = TypePrimary
-					addr.InstanceTypeSet = false
-					results = append(results, &StateFilterResult{
-						Path:    addr.Path,
-						Address: addr.String(),
-						Parent:  resourceResult,
-						Value:   r.Primary,
-					})
-				}
-
-				for _, instance := range r.Deposed {
-					if f.relevant(a, instance) {
-						addr.InstanceType = TypeDeposed
-						addr.InstanceTypeSet = true
-						results = append(results, &StateFilterResult{
-							Path:    addr.Path,
-							Address: addr.String(),
-							Parent:  resourceResult,
-							Value:   instance,
-						})
-					}
-				}
+					Parent:  resourceResult,
+					Value:   instance,
+				})
 			}
 		}
 	}
```
