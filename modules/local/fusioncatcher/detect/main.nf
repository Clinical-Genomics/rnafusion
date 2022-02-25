process FUSIONCATCHER {
    tag "$meta.id"
    label 'process_high'

    // TODO: Make a singularity container
    conda (params.enable_conda ? "bioconda::fusioncatcher=1.33" : null)
    if (workflow.containerEngine == 'singularity' && !params.singularity_pull_docker_container) {
        // container "https://depot.galaxyproject.org/singularity/fusioncatcher:1.30--hdfd78af_1"
        container "docker.io/clinicalgenomics/fusioncatcher:1.33"
    } else {
        container "docker.io/clinicalgenomics/fusioncatcher:1.33"
    }

    input:
    tuple val(meta), path(fasta)
    path reference

    output:
    tuple val(meta), path("*.fusioncatcher.fusion-genes.txt")   , optional:true, emit: fusions
    tuple val(meta), path("*.fusioncatcher.summary.txt")        , optional:true, emit: summary
    tuple val(meta), path("*.fusioncatcher.log")                               , emit: log
    path "versions.yml"

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def reads = fasta.toString().replace(" ", ",")
    """
    fusioncatcher.py \\
        -d $reference \\
        -i $reads \\
        -p $task.cpus \\
        -o . \\
        --skip-blat \\
        $args

    mv final-list_candidate-fusion-genes.txt ${prefix}.fusioncatcher.fusion-genes.txt
    mv summary_candidate_fusions.txt ${prefix}.fusioncatcher.summary.txt
    mv fusioncatcher.log ${prefix}.fusioncatcher.log

    fusioncatcher.py --version | sed 's/fusioncatcher.py //' > versions.yml
    """
}
