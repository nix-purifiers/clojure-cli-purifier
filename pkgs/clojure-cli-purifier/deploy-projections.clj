;; SPDX-License-Identifier: MIT
(ns purifier.deploy-projections
  (:require [clojure.data.json :as json]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [deps-deploy.deps-deploy :as deploy])
  (:import [org.apache.maven.settings.building DefaultSettingsBuilderFactory
            DefaultSettingsBuildingRequest]))

(let [[repository catalog target dry-run] *command-line-args*
      description (json/read-str (slurp catalog) :key-fn keyword)
      modules (or (:publications description) (:modules description))
      [id url] (if (seq target)
                 (str/split target #"=" 2)
                 [(:id deploy/default-repo-settings) (:url deploy/default-repo-settings)])
      settings-file (io/file (System/getProperty "user.home") ".m2/settings.xml")
      settings (when (.isFile settings-file)
                 (.. (DefaultSettingsBuilderFactory.) newInstance
                     (build (doto (DefaultSettingsBuildingRequest.)
                              (.setUserSettingsFile settings-file)
                              (.setSystemProperties (System/getProperties))))
                     getEffectiveSettings))
      server (first (filter #(= id (.getId %)) (when settings (.getServers settings))))
      destination {id {:url url
                       :username (or (System/getenv "CLOJARS_USERNAME") (when server (.getUsername server)))
                       :password (or (System/getenv "CLOJARS_PASSWORD") (when server (.getPassword server)))}}]
  (doseq [{:keys [group name version]} modules]
    (let [directory (io/file repository (str/replace group "." "/") name version)
          prefix (str name "-" version)
          files (sort-by #(.getName %) (filter #(.isFile %) (.listFiles directory)))
          artifacts (into {}
                          (for [file files
                                :let [filename (.getName file)]
                                :when (and (str/starts-with? filename prefix)
                                           (not (re-find #"\.(md5|sha1|sha256|sha512|asc)$" filename)))
                                :let [suffix (subs filename (count prefix))
                                      [classifier extension] (if (str/starts-with? suffix ".")
                                                               [nil (subs suffix 1)]
                                                               (str/split (subs suffix 1) #"\." 2))]]
                            [[:extension extension :classifier classifier] (.getPath file)]))]
      (if (= dry-run "1")
        (do
          (when-let [jar (get artifacts [:extension "jar" :classifier nil])]
            (println "jar:" jar))
          (println "pom:" (get artifacts [:extension "pom" :classifier nil]))
          (println "deploy:" (str group ":" name ":" version) "->" id))
        (deploy/deploy* {:installer :remote
                        :coordinates {:group-id group :artifact-id name :version version}
                        :artifact-map artifacts :repository destination}))))
  (shutdown-agents))
