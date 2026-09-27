FROM eclipse-temurin:21-jre

# Pinned GraphHopper release (CLAUDE.md rule 4). Upgrade deliberately only.
ARG GH_VERSION=11.0
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL -o /opt/graphhopper-web.jar \
    "https://repo1.maven.org/maven2/com/graphhopper/graphhopper-web/${GH_VERSION}/graphhopper-web-${GH_VERSION}.jar"

WORKDIR /opt
COPY config.yml /opt/config.yml
COPY custom_models /opt/custom_models

EXPOSE 8989
# The graph is (re)built automatically when /data/graph-cache is missing (weekly job deletes it after a new extract).
CMD ["sh", "-c", "java $JAVA_OPTS -Ddw.graphhopper.datareader.file=$GH_PBF -jar /opt/graphhopper-web.jar server /opt/config.yml"]
