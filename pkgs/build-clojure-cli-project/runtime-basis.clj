;; SPDX-License-Identifier: MIT
;; Read the basis of this exact native application invocation, not tool caches.
(require '[clojure.edn :as edn] '[clojure.string :as str])
(defn json [value]
  (cond
    (nil? value) "null"
    (string? value) (pr-str value)
    (map? value) (str "{" (str/join "," (map (fn [[k v]] (str (json k) ":" (json v))) value)) "}")
    (coll? value) (str "[" (str/join "," (map json value)) "]")
    :else (str value)))
(let [basis (edn/read-string (slurp (System/getProperty "clojure.basis")))
      libs (:libs basis)]
  (spit (System/getenv "PURIFIER_RUNTIME_BASIS")
        (json {"modules"
               (mapv (fn [[library coordinate]]
                       {"library" (str library)
                        "group" (or (namespace library) (name library))
                        "name" (name library)
                        "version" (:mvn/version coordinate)
                        "requested" (get-in basis [:deps library :mvn/version])
                        "paths" (:paths coordinate)
                        "root" (contains? (:parents coordinate) [])
                        "dependencies" (mapv (comp str key)
                                             (filter (fn [[_ child]]
                                                       (some #{library} (:dependents child)))
                                                     (sort-by (comp str key) libs)))})
                     (sort-by (comp str key) libs))})))
